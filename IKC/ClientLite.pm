package POE::Component::IKC::ClientLite;

############################################################
# $Id$
# By Philp Gwyn <fil@pied.nu>
#
# Copyright 1999 Philip Gwyn.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# Contributed portions of IKC may be copyright by their respective
# contributors.  

use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $error $request);

use Socket;
use IO::Socket;
use IO::Select;
use POE::Component::IKC::Specifier;
use Data::Dumper;
use POSIX qw(:errno_h);
use Carp;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(create_ikc_client);
$VERSION = '0.09';

sub DEBUG { 0 }

$request=0;

###############################################################################
#----------------------------------------------------
# This is just a convenient way to create servers.  To be useful in
# multi-server situations, it probably should accept a bind address
# and port.
sub create_ikc_client
{
    my $package;
    $package = (scalar(@_) & 1 ? shift(@_) : __PACKAGE__);
    my(%parms)=@_;
#    $parms{on_connect}||=sub{};         # would be silly for this to be blank
    $parms{ip}||='localhost';           
    $parms{port}||=603;                 # POE! (almost :)
    $parms{name}||="Client$$";
    $parms{timeout}||=30;
    $parms{serialiser}||=_default_freezer();

    my %self;
    @self{qw(ip port name serialiser timeout)}=
            @parms{qw(ip port name serialiser timeout)};

    eval {
        @{$self{remote}}{qw(freeze thaw)}=_get_freezer($self{serialiser});
    };

    if($@) {
        $self{error}=$error=$@;
        return;
    }
    my $self=bless \%self, $package;
    $self->{remote}{aliases}={};
    $self->{remote}{name}="$self->{ip}:$self->{port}";

    $self->connect and return $self;
    return;
}

sub name { $_[0]->{name}; }

#----------------------------------------------------
sub connect
{
    my($self)=@_;
    return 1 if($self->{remote}{connected} and $self->{remote}{socket} and 
                $self->ping);  # are we already connected?

    my $remote=$self->{remote};
    delete $remote->{socket};
    delete $remote->{connected};

    my $name=$remote->{name};
    DEBUG && print "Connecting to $name...\n";
    my $sock;

    eval {
        local $SIG{__DIE__}='DEFAULT';
        local $SIG{__WARN__};
        $sock=IO::Socket::INET->new(PeerAddr=>$self->{ip},
                                     PeerPort=>$self->{port},
                                     Proto=>'tcp', Timeout=>$self->{timeout},);
        die "Unable to connect to $name: $!\n" unless $sock;
        $sock->autoflush(1);
        my($ors, $irs)=($sock->output_record_separator("\r\n"), 
                        $sock->input_record_separator("\r\n"));
        $sock->print('HELLO');
        my $resp;
        while (defined($resp=$sock->getline))       # phase 000
        {
            chomp($resp);
            last if $resp eq 'DONE';
            die "Invalid IAM response from $name: $resp\n" 
                unless $resp=~/^IAM\s+([-:.\w]+)$/;
            $remote->{name}||=$1;
            $self->{ping}||="poe://$1/IKC/ping";
            $remote->{aliases}->{$1}=1;
            $sock->print('OK');
        }
        die "Phase 000: $!\n" unless defined $resp;


        $sock->print("IAM $self->{name}");          # phase 001
        chomp($resp=$sock->getline);
        die "Phase 001: $!\n" unless defined $resp;
        die "Didn't get OK from $name\n" unless $resp eq 'OK';
        $sock->print("DONE");

        $sock->print("FREEZER $self->{serialiser}");# phase 002
        chomp($resp=$sock->getline);
        die "Phase 002: $!\n" unless defined $resp;
        die "$name refused $self->{serialiser}\n" unless $resp eq 'OK';

        $sock->print('WORLD');                      # phase 003
        chomp($resp=$sock->getline);
        die "Phase 003: $!\n" unless defined $resp;
        die "Didn't get UP from $name\n" unless $resp eq 'UP';        
        $sock->output_record_separator($ors);
        $sock->input_record_separator($irs);
    };
    if($@)
    {
        $self->{error}=$error=$@;
        return;
    } 
    $remote->{socket}=$sock;
    $remote->{connected}=1;
    return 1;
}

#----------------------------------------------------
sub error
{
    return $error;
}
#----------------------------------------------------
sub ping
{
    my($self)=@_;
    my $ret=eval {
        my $rsvp={kernel=>$self->{name}, 
                  session=>'IKC', state=>'pong'
                 };
        my $r=$self->_send_msg({event=>$self->{ping}, params=>'PING', 
                                rsvp=>$rsvp});
        return unless $r;
        my $pong=$self->_response($rsvp);
        return 1 if $pong and $pong eq 'PONG';
    }; 
    $self->{error}=$error=$@ if $@;
    $self->{remote}{connected}=$ret;
    return $ret;
}

#----------------------------------------------------
sub disconnect
{
    my($self)=@_;
    $self->post('IKC/unregister', $self->{name}) if $self->{remote};
    delete @{$self->{remote}}{qw(socket connected name aliases)};
    $self->{remote}={};
}

sub DESTROY 
{
    my($self)=@_;
    $self->disconnect;
}
sub END
{
    # print 'end';
}

#----------------------------------------------------
# Post an event, maybe waits for a response and throws it away
#
sub post
{
    my($self, $spec, $params)=@_;
    unless(ref $spec or $spec=~m(^poe:)) {
        
        unless($self->{remote}{name}) {
            $self->{error}=$error="Attempting to post $spec to unknown kernel";
            carp $error;
            return;
        }

        $spec="poe://$self->{remote}{name}/$spec";
    }

    my $ret=eval { 
        return 0 if(0==$self->_try_send({event=>$spec, params=>$params}));
        1;
    };
    if($@) {
        $self->{error}=$error=$@;
        return;
    }
    return $ret;
}

#----------------------------------------------------
# posts an event, waits for the response, returns the response
sub call
{
    my($self, $spec, $params)=@_;
    $spec="poe://$self->{remote}{name}/$spec" unless ref $spec or $spec=~m(^poe:);

    my $ret;
    my $rsvp={kernel=>$self->{name}, session=>'IKCLite',
              state=>'response'.$request++};
    $ret=eval { 
        return unless $self->_try_send({event=>$spec, params=>$params, 
                                        rsvp=>$rsvp
                                       }); 
        DEBUG && print "Waiting for response...\n";
        return $self->_response($rsvp);
    };
    if($@) {
        $self->{error}=$error=$@;
        return;
    }
    return $ret;
}

#----------------------------------------------------
# posts an event, waits for the response, returns the response
# this differs from call() in that the foreign server may
# need many states before getting a response
sub post_respond
{
    my($self, $spec, $params)=@_;
    $spec="poe://$self->{remote}{name}/$spec" unless ref $spec or $spec=~m(^poe:);

    my $ret;
    my $rsvp={kernel=>$self->{name}, session=>'IKCLite',
              state=>'response'.$request++};
    $ret=eval { 
        return unless $self->_try_send({event=>$spec, 
                                        params=>[$params, $rsvp], 
                                       }); 
        DEBUG && print "Waiting for response...\n";
        return $self->_response($rsvp);
    };
    if($@) {
        $self->{error}=$error=$@;
        return;
    }
    return $ret;
}

#----------------------------------------------------
sub _try_send
{
    my($self, $msg)=@_;
    return unless $self->{remote}{connected} or $self->connect();

    my $ret=$self->_send_msg($msg);
    DEBUG && print "Sending message...\n";
    if(defined $ret and $ret==0)
    {
        return 0 unless $self->connect();
        DEBUG && print "Retry message...\n";
        $ret=$self->_send_msg($msg);
    }
    return $ret;
}

#----------------------------------------------------
sub _send_msg
{
    my($self, $msg)=@_;

    my $e=$msg->{rsvp} ? 'call' : 'post';

    my $to=specifier_parse($msg->{event});
    unless($to) {
        croak "Bad message ", Dumper $msg;
    }
    unless($to) {
        warn "Bad or missing 'to' parameter '$msg->{event}' to poe:/IKC/$e\n";
        return;
    }
    unless($to->{session}) {
        warn "Need a session name in poe:/IKC/$e";
        return;
    }
    unless($to->{state})   {
        carp "Need a state name in poe:IKC/$e";
        return;
    }

    my $frozen = $self->{remote}{freeze}->($msg);
    my $raw=length($frozen) . "\0" . $frozen;

    unless($self->{remote}{socket}->syswrite($raw, length $raw))
    {
        $self->{connected}=0;
        return 0 if($!==EPIPE);
        die "Error writing: $!\n";
    }
    return 1;
}


#----------------------------------------------------
sub _response
{
    my($self, $rsvp)=@_;

    $rsvp=specifier_parse($rsvp);
    my $remote=$self->{remote};

    my $timeout=$remote->{socket}->timeout();
    my $stopon=time+$timeout;

    my $select=IO::Select->new() or die $!;     # create the select object
    $select->add($remote->{socket});

    my(@ready, $s, $raw, $frozen, $ret, $l, $need);
    $raw='';

    while ($stopon >= time)                     # do it until time's up
    {
        @ready=$select->can_read($stopon-time); # this is the select
        last unless @ready;                     # nothing ready == timout
    
        foreach $s (@ready)                     # let's see what's ready...
        {
            die "Hey!  $s isn't $remote->{socket}" 
                unless $s eq $remote->{socket};
        }
        DEBUG && print "Got something...\n";
        
                                    # read in another chunk
        $l=$remote->{socket}->sysread($raw, 512, length($raw)); 

        unless(defined $l) {                    # disconnect, maybe?
            $remote->{connected}=0 if $!==EPIPE;               
            die "Error reading: $!\n";
        }

        if(not $need and $raw=~s/(\d+)\0//s) {  # look for a marker?
            $need=$1 ;
            DEBUG && print "Need $need bytes...\n";
        }

        next unless $need;                      # still looking...

        if(length($raw) >= $need)               # do we have all we want?
        {
            DEBUG && print "Got it all...\n";

            $frozen=substr($raw, 0, $need);     # seems so...
            substr($raw, 0, $need)='';
            my $msg=$self->{remote}{thaw}->($frozen);   # thaw the message
            my $to=specifier_parse($msg->{event});
            DEBUG && print Dumper $msg;

            die $msg->{params} if($msg->{is_error});    # throw an error out
            DEBUG && print "Not an error...\n";

                # make sure it's what we're waiting for...
            if($to->{session} ne 'IKC' and $to->{session} ne 'IKCLite')
            {
                warn "Unknown session $to->{session}\n";
                DEBUG && print "Not for us!  ($to->{session})...\n";
                next;
            }
            if($to->{session} ne $rsvp->{session} or
               $to->{state} ne $rsvp->{state})
            {
                warn specifier_name($to). " received, expecting " .
                     specifier_name($rsvp). "\n";
                DEBUG && print "Not for us!  ($to->{session}/$to->{state})...\n";
                next;
            }
            return $msg->{params};              # finaly!
        }
    }
    $remote->{connected}=0;
    die "Timed out waiting for resonse\n";
}









#------------------------------------------------------------------------------
# Try to require one of the default freeze/thaw packages.
sub _default_freezer
{
  local $SIG{'__DIE__'} = 'DEFAULT';
  my $ret;

  foreach my $p (qw(Storable FreezeThaw)) {
    eval { require "$p.pm"; import $p ();};
    warn $@ if $@;
    return $p if $@ eq '';
  }
  die __PACKAGE__." requires Storable or FreezeThaw\n";
}

sub _get_freezer
{
    my($freezer)=@_;
    unless(ref $freezer) {
      unless(exists $::{$freezer.'::'}) {
        eval {require "$freezer.pm"; import $freezer ();};
        croak $@ if $@;
      }
    }

    # Now get the methodes we want
    my $freeze=$freezer->can('freeze') || $freezer->can('nfreeze');
    carp "$freezer doesn't have a freeze method" unless $freeze;
    my $thaw=$freezer->can('thaw');
    carp "$freezer doesn't have a thaw method" unless $thaw;


    # If it's an object, we use closures to create a $self->method()
    my $tf=$freeze;
    my $tt=$thaw;
    if(ref $freezer) {
        $tf=sub {$freeze->($freezer, @_)};
        $tt=sub {$thaw->($freezer, @_)};
    }
    return($tf, $tt);
}

1;

__DATA__

$Log$