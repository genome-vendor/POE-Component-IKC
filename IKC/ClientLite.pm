package POE::Component::IKC::ClientLite;

############################################################
# $Id: ClientLite.pm,v 1.14 2002/05/02 19:35:54 fil Exp $
# By Philp Gwyn <fil@pied.nu>
#
# Copyright 1999,2002 Philip Gwyn.  All rights reserved.
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
$VERSION = '0.14';

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
*spawn=\&create_ikc_client;

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
                                     xxProto=>'tcp', Timeout=>$self->{timeout},);
        die "Unable to connect to $name: $!\n" unless $sock;
        $sock->autoflush(1);
        local $/="\cM\cJ";
        local $\="\cM\cJ";
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
    return $_[0]->{error} if @_==1;
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
    # 2001/01 why did we try to unregister ourselves?  unregister wouldn't
    # be safe for remote kernels anyway
    # $self->call('IKC/unregister', $self->{name}) if $self->{remote};
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
    DEBUG and print 'end';
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
            # carp $error;
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

    my $rsvp={kernel=>$self->{name}, session=>'IKCLite',
              state=>'response'.$request++};
    
    my $req={event=>$spec, params=>$params, 
             rsvp=>$rsvp, 'wantarray'=>wantarray(),
            };
    my @ret=eval { 
        return unless $self->_try_send($req); 
        DEBUG && print "Waiting for response...\n";
        return $self->_response($rsvp, $req->{wantarray});
    };
    if($@) {
        $self->{error}=$error=$@;
        return;
    }
    return @ret if $req->{wantarray};
    return $ret[0];
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
    if(defined $ret and $ret==0) {
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

    unless($self->{remote}{socket}->opened()) {
        $self->{connected}=0;
        $self->{error}=$error="Socket not open";
        return 0;
    }
    unless($self->{remote}{socket}->syswrite($raw, length $raw)) {
        $self->{connected}=0;
        return 0 if($!==EPIPE);
        $self->{error}=$error="Error writing: $!\n";
        return 0;
    }
    return 1;
}


#----------------------------------------------------
sub _response
{
    my($self, $rsvp, $wantarray)=@_;

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

            die "$msg->{params}\n" if($msg->{is_error});    # throw an error out
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

            if($wantarray) {
                DEBUG and print "Wanted an array\n";
                return @{$msg->{params}} if ref $msg->{params} eq 'ARRAY';
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

  foreach my $p (qw(Storable FreezeThaw POE::Component::IKC::Freezer)) {
    my $q=$p;
    $q=~s(::)(/)g;
    eval { require "$q.pm"; import $p ();};
    DEBUG and warn $@ if $@;
    return $p if $@ eq '';
  }
  die __PACKAGE__." requires Storable or FreezeThaw or POE::Component::IKC::Freezer\n";
}

sub _get_freezer
{
    my($freezer)=@_;
    unless(ref $freezer) {
    my $symtable=$::{"main::"};
    my $loaded=1;                       # find out of the package was loaded
    foreach my $p (split /::/, $freezer) {
        unless(exists $symtable->{"$p\::"}) {
            $loaded=0;
            last;
        }
        $symtable=$symtable->{"$p\::"};
    }

    unless($loaded) {        my $q=$freezer;
        $q=~s(::)(/)g;
        eval {require "$q.pm"; import $freezer ();};
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


=head1 NAME

POE::Component::IKC::ClientLite - Small client for IKC

=head1 SYNOPSIS

    use POE::Component::IKC::ClientLite;

    $poe=create_ikc_client(port=>1337);
    die POE::Component::IKC::ClientLite::error() unless $poe;

    $poe->post("Session/event", $param)
        or die $poe->error;
    
    # bad way of getting a return value
    my $foo=$poe->call("Session/other_event", $param)
        or die $poe->error;

    # better way of getting a return value
    my $ret=$poe->post_respond("Session/other_event", $param)
        or die $poe->error;

    # make sure connectin is aliave
    $poe->ping() 
        or $poe->disconnect;

=head1 DESCRIPTION

ClientLite is a small, pure-Perl IKC client implementation.  It is very basic
because it is intented to be used in places where POE wouldn't fit, like
mod_perl.

It handles automatic reconnection.  When you post an event, ClientLite will
try to send the packet over the wire.  If this fails, it tries to reconnect. 
If it can't it returns an error.  If it can, it will send he packet again.  If
*this* fails, well, tough luck.

=head1 METHODS

=head2 create_ikc_client

Creates a new PoCo::IKC::ClientLite object.  Parameters are supposedly
compatible with PoCo::IKC::Client, but serializers and unix sockets aren't
handled yet...

=head2 connect

    $poe->connect or die $poe->error;

Connects to the remote kernel if we aren't already. You can use this method
to make sure that the connection is open before trying anything.

Returns true if connection was successful, false if not.  You can check
C<error> to see what the problem was.


=head2 disconnect

Disconnects from remote IKC server.

=head2 error

    my $error=POE::Component::IKC::ClientLite::error();
    $error=$poe->error();

Returns last error.  Can be called as a object method, or as a global
function.

=head2 post

    $poe->post($specifier, $data);

Posts the event specified by C<$specifier> to the remote kernel.  C<$data>
is any parameters you want to send along with the event.  It will return 1
on success (ie, data could be sent... not that the event was received) and
undef() if we couldn't connect or reconnect to remote kernel.

=head2 post_respond

    my $back=$poe->post_respond($specifier, $data);

Posts the event specified by C<$specifier> to the remote kernel.  C<$data>
is any parameters you want to send along with the event.  It waits until
the remote kernel sends a message back and returns it's payload.  Waiting
timesout after whatever you value you gave to C<create_ikc_client>.

Events on the far side have to be aware of post_respond.  In particular,
ARG0 is not C<$data> as you would expect, but an arrayref that contains
C<$data> followed by a specifier that should be used to post back.

    sub my_event
    {
        my($kernel, $heap, $args)=@_[KERNEL, HEAP, ARG0];
        my $p=$args->[0];
        my $heap->{rsvp}=$args->[1];
        # .... do lotsa stuff here
    }

    # eventually, we are finished
    sub finished
    {
        my($kernel, $heap, $return)=@_[KERNEL, HEAP, ARG0];
        $kernel->post(IKC=>'post', $heap->{rsvp}, $return);
    }

=head2 call

    my $back=$poe->call($specifier, $data);

This is the bad way to get information back from the a remote event. 
Follows the expected semantics from standard POE.  It works better then
post_respond, however, because it doesn't require you to change your
interface or write a wrapper.

=head2 ping

    unless($poe->ping) {
        # connection is down!  connection is down!
    }
    
Find out if we are still connected to the remote kernel.  This method will
NOT try to reconnect to the remote server

=head2 name

Returns our local name.  This is what the remote kernel thinks we are
called.  I can't really say this is the local kernel name, because, well,
this isn't really a kernel.  But hey.

=head1 AUTHOR

Philip Gwyn, <perl-ikc at pied.nu>

=head1 SEE ALSO

L<POE>, L<POE::Component::IKC>

=cut




$Log: ClientLite.pm,v $
Revision 1.14  2002/05/02 19:35:54  fil
Updated Chanages.
Merged alias listing for publish/subtract
Moved version

Revision 1.13  2001/09/06 23:13:42  fil
Added doco for Responder->spawn
Responder->spawn always returns true so that JAAS's factory doesn't complain

Revision 1.12  2001/08/02 03:26:50  fil
Added documentation.

Revision 1.11  2001/07/24 20:45:54  fil
Fixed some win32 things like WSAEAFNOSUPPORT
Added more tests to t/20_clientlite.t

Revision 1.10  2001/07/13 06:59:45  fil
Froze to 0.13

Revision 1.9  2001/07/13 01:14:00  fil
Fixed loading of serializers that contain :: in Client and ClientLite
Fixed serializer negociation in Channel

Revision 1.8  2001/07/12 05:36:22  fil
Added doco to ClientLite

Revision 1.7  2001/07/12 04:15:17  fil
Added small and totaly incomplete test case for IKC::ClientLite
PoCo::IKC::ClientLite now doesn't throw warnings when it can't
    find Storable or FreezeThaw.

Revision 1.6  2001/07/12 03:49:59  fil
Fixed bug in ClientLite for loading Freezers that have :: in their names

Revision 1.5  2001/07/12 03:46:33  fil
Added IKC::Freezer to ClientLite

Revision 1.4  2001/07/12 03:42:18  fil
Added IKC::Channel::spawn
Fixed IKC::Channel so that you can specify what module to use for
    serialization.
Added IKC::Freezer

Revision 1.3  2001/07/06 02:27:51  fil
Version 0.13pre9

Revision 1.2  2001/07/06 02:23:35  fil
Fixed bunch of things in doco
Changed my e-mail address

Revision 1.1.1.1  2001/06/07 04:32:02  fil
initial import to CVS
