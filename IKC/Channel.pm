package POE::Component::IKC::Channel;

############################################################
# $Id$
# Based on tests/refserver.perl
# Contributed by Artur Bergman <artur@vogon-solutions.com>
# Revised for 0.06 by Rocco Caputo <troc@netrus.net>
# Turned into a module by Philp Gwyn <fil@pied.nu>
#
# Copyright 1999 Philip Gwyn.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# Contributed portions of IKC may be copyright by their respective
# contributors.  

use strict;
use Socket;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);
use POE qw(Wheel::ListenAccept Wheel::ReadWrite Wheel::SocketFactory
           Driver::SysRW Filter::Reference Filter::Line
          );
use POE::Component::IKC::Responder;
use Data::Dumper;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(create_ikc_channel);
$VERSION = '0.12';

sub DEBUG { 0 }

###############################################################################
# Channel instances are created by the listening session to handle
# connections.  They receive one or more thawed references, and pass
# them to the running Responder session for processing.

#----------------------------------------------------
# This is just a convenient way to create channels.

sub create_ikc_channel
{
  my($handle, $name, $on_connect, $subscribe, $rname) = @_;

  new POE::Session( _start => \&channel_start,
                    _stop  => \&channel_shutdown,
                    _default => \&channel_default,
                    error  => \&channel_error,

                    receive => \&channel_receive,
                    'send'  => \&channel_send,
                    'done'  => \&channel_done,
                    'close' => \&channel_close,
                    server_000 => \&server_000,
                    server_001 => \&negociate_001,
                    server_002 => \&server_002,
                    server_003 => \&server_003,
                    client_000 => \&client_000,
                    client_001 => \&negociate_001,
                    client_002 => \&client_002,
                    client_003 => \&client_003,
                    [ $handle, $name, $on_connect, $subscribe, $rname]
                  );
}

#----------------------------------------------------
# Accept POE's standard _start event, and begin processing data.
sub channel_start 
{
    my ($kernel, $heap, $session, $handle, $name, $on_connect, $subscribe, $rname) = 
                @_[KERNEL, HEAP, SESSION, ARG0, ARG1, ARG2, ARG3, ARG4];

    my @name=unpack_sockaddr_in(getsockname($handle));
    $name[1]=inet_ntoa($name[1]);
    if($name)
    {
        $heap->{kernel_name}=$name;
        $heap->{kernel_aliases}=[join ':', @name[1,0]];
    } else
    {
        $heap->{kernel_name}=join ':', @name[1,0];
        $heap->{kernel_aliases}=[];
    }
    

    if($rname)
    {
        $heap->{remote_kernel}=$rname; 
    } else
    {
        @name=unpack_sockaddr_in(getpeername($handle));
        $name[1]=inet_ntoa($name[1]);
        $heap->{remote_kernel}=join ':', @name[1,0];
    }

    DEBUG && print "Channel session $heap->{kernel_name}<->$heap->{remote_kernel} created.\n";

                                        # start reading and writing
    $heap->{wheel_client} = new POE::Wheel::ReadWrite
    ( Handle     => $handle,                    # on this handle
      Driver     => new POE::Driver::SysRW,     # using sysread and syswrite
      InputState => 'none',
      Filter     => POE::Filter::Line->new(),   # use a line filter for negociations
      ErrorState => 'error',            # generate this event on error
    );

    $session->option(default=>1);
    $heap->{on_connect}=$on_connect if ref($on_connect);
    $heap->{subscribe}=$subscribe if ref($subscribe) and @$subscribe;
    _set_phase($kernel, $heap, '000');
}

#----------------------------------------------------
sub _negociation_done
{
    my($kernel, $heap)=@_;
    DEBUG && 
            print "Negociation done ($heap->{kernel_name}<->$heap->{remote_kernel}).\n";

    # generate this event on input
    $heap->{'wheel_client'}->event(InputState => 'receive');

    $heap->{filter}||=POE::Filter::Reference->new();
    # parsing I/O as references
    $heap->{wheel_client}->set_filter($heap->{filter}); 
    delete $heap->{filter};

    # Register the foreign kernel with the responder
    create_ikc_responder();
    push @{$heap->{remote_aliases}}, $heap->{remote_kernel};
    $kernel->call('IKC', 'register', $heap->{remote_aliases});
    
    # Now that we're set up properly
    if($heap->{subscribe})                  # subscribe to wanted sessions
    {
        $kernel->call('IKC', 'subscribe', $heap->{subscribe}, 'done');
    } else
    {
        $kernel->yield('done');
    }

    return;
}

#----------------------------------------------------
# This is the subscription callback
sub channel_done
{
    my($heap, $subscribed)=@_[HEAP, ARG0];
    if($heap->{subscribe})
    {
        my %count;
        foreach my $spec (@$subscribed, @{$heap->{subscribe}})
        {   $count{$spec}++;    
        }
        my @missing=grep { $count{$_} != 2 } keys %count;

        if(@missing)
        {
            die "Unable to subscribe to ".join(', ', @missing)."\n";
        } 
    }

    if($heap->{on_connect})            # or call the on_connected
    {
        $heap->{on_connect}->();
        delete $heap->{on_connect};    
    }    
    delete $heap->{subscribe};
}

#----------------------------------------------------
#### DEAL WITH NEGOCIATION PHASE
sub _set_phase
{
    my($kernel, $heap, $phase)=@_;
    if($phase eq 'ZZZ')
    {
        _negociation_done($kernel, $heap);
        return;
    } 

    my $neg='server_';
    $neg='client_' if($heap->{on_connect});

        # generate this event on input
    $heap->{'wheel_client'}->event(InputState => $neg.$phase);
    DEBUG && print "Negociation phase $neg$phase.\n";
    $kernel->yield($neg.$phase);               # Start the negociation phase
    return;
}

# First server state is
sub server_000
{
    my ($heap, $kernel, $line)=@_[HEAP, KERNEL, ARG0];

    unless(defined $line)
    {
        # wait for client to send HELLO

    } elsif($line eq 'HELLO')
    {
        $heap->{'wheel_client'}->put('IAM '.$kernel->ID());
                                          # put other server aliases here
        $heap->{aliases001}=[$heap->{kernel_name}, 
                             @{$heap->{kernel_aliases}}];   
        _set_phase($kernel, $heap, '001');

    } else    
    {
        warn "Client sent '$line' during phase 000\n";
    }
    return;
}

# We tell who we are
sub negociate_001
{
    my ($heap, $kernel, $line)=@_[HEAP, KERNEL, ARG0];
    
    unless(defined $line)
    {

    } elsif($line eq 'OK')
    {
        my $a=pop @{$heap->{aliases001}};
        if($a)
        {
            $heap->{'wheel_client'}->put("IAM $a");
        } else
        {
            delete $heap->{aliases001};
            $heap->{'wheel_client'}->put('DONE');   
            _set_phase($kernel, $heap, '002');
        }
    } else
    {
        warn "Recieved '$line' during phase 001\n";
    }
    return;
}

# We find out who the client is
sub server_002
{
    my ($heap, $kernel, $line)=@_[HEAP, KERNEL, ARG0];

    unless(defined $line)
    {

    } elsif($line eq 'DONE')
    {
        _set_phase($kernel, $heap, '003');

    } elsif($line =~ /^IAM\s+([-:.\w]+)$/)
    {   
        # Register this kernel alias with the responder
        push @{$heap->{remote_aliases}}, $1;
        $heap->{'wheel_client'}->put('OK');   

    } else    
    {
        warn "Client sent '$line' during phase 002\n";
    }
    return;
}

# We find out what type of serialisation the client wants
sub server_003
{
    my ($heap, $kernel, $line)=@_[HEAP, KERNEL, ARG0];

    unless(defined $line)
    {
        # wait for client to say something

    } elsif($line =~ /^FREEZER\s+([-:\w]+)$/)
    {   
        my $package=$1;
        eval
        {
            $heap->{filter}=POE::Filter::Reference->new($package);
        };
        if($@)
        {
            DEBUG && print "Client wanted $package, but we can't : $@";
            $heap->{wheel_client}->put('NOT');
        } else
        {
            DEBUG && print "Using $package\n";
            $heap->{wheel_client}->put('OK');
        }
    } elsif($line eq 'WORLD')
    {
        # last bit of the dialog has to come from us :(
        $heap->{wheel_client}->put('UP');   
        _set_phase($kernel, $heap, 'ZZZ');     
    } else    
    {
        warn "Client sent '$line' during phase 003\n";
    }
    return;
}

#----------------------------------------------------
# These states is invoked for each line during the negociation phase on 
# the client's side

## Start negociation and listen to who the server is
sub client_000
{
    my ($heap, $kernel, $line)=@_[HEAP, KERNEL, ARG0];

    unless(defined $line)
    {
        $heap->{wheel_client}->put('HELLO');

    } elsif($line =~ /^IAM\s+([-:.\w]+)$/)
    {   
        # Register this kernel alias with the responder
        push @{$heap->{remote_aliases}}, $1;
        $heap->{wheel_client}->put('OK');

    } elsif($line eq 'DONE')
    {
        $heap->{'wheel_client'}->put('IAM '.$poe_kernel->ID());
        $heap->{aliases001}=[$heap->{kernel_name}, 
                             @{$heap->{kernel_aliases}}];
        _set_phase($kernel, $heap, '001');

    } else
    {
        warn "Server sent '$line' during negociation phase 000\n";
    }
    return;
}

# 
sub client_002
{
    my ($heap, $kernel, $line)=@_[HEAP, KERNEL, ARG0];
    
    unless(defined $line)
    {
        $heap->{serial002}=$heap->{serialisers};
        $line=$heap->{serial002} ? 'NOT' : 'OK';
    }

    if($line eq 'NOT')
    {
        my $ft = unshift @{$heap->{serial002}};
    
        if($ft)
        {
            $heap->{'wheel_client'}->put('FREEZER '.$ft);   
        } else
        {
            die "Server doesn't like our list of serialisers ", 
                    join ', ', @{$heap->{serialisers}};
        }
    } elsif($line eq 'OK')
    {
        delete $heap->{serial002};  
        _set_phase($kernel, $heap, '003');
    } else
    {
        warn "Server sent '$line' during negociation phase 002\n";
    }
}

# Game over
sub client_003
{
    my ($heap, $kernel, $line)=@_[HEAP, KERNEL, ARG0];

    unless(defined $line)
    {
        $heap->{'wheel_client'}->put('WORLD');
    } elsif($line eq 'UP')
    {
        _set_phase($kernel, $heap, 'ZZZ');
    } else    
    {
        warn "Server sent '$line' during phase 003\n";
    }
    return;
}


#----------------------------------------------------
# This state is invoked for each error encountered by the session's
# ReadWrite wheel.

sub channel_error 
{
    my ($heap, $kernel, $operation, $errnum, $errstr) =
        @_[HEAP, KERNEL, ARG0, ARG1, ARG2];

    if ($errnum) {
        # DEBUG && 
        print "Channel encountered $operation error $errnum: $errstr\n";
    }
    else {
        DEBUG && 
            print "The channel's client closed its connection ($heap->{kernel_name}<->$heap->{remote_kernel})\n";
    }
    $kernel->call('IKC', 'unregister', $heap->{remote_aliases});
    delete $heap->{remote_aliases};
                                        # either way, shut down
    delete $heap->{wheel_client};
}

#----------------------------------------------------
#
sub channel_default
{
    my($event)=$_[STATE];
    DEBUG && print "Unknown event $event posted to IKC::Channel\n"
        if $event !~ /^_/;
    return;
}

#----------------------------------------------------
# Process POE's standard _stop event by shutting down.
sub channel_shutdown 
{
    my $heap = $_[HEAP];
#    warn "$heap channel_shutdown\n";
    DEBUG && print "Channel has shut down.\n";
    delete $heap->{wheel_client};
}

###########################################################################
## Next two events forward messages between Wheel::ReadWrite and the
## Responder
## Because the Responder know which foreign kernel sent a request,
## these events fill in some of the details.

#----------------------------------------------------
# Foreign kernel sent us a request
sub channel_receive
{
    my ($kernel, $heap, $request) = @_[KERNEL, HEAP, ARG0];

    DEBUG && warn "$$: Recieved data...\n";
    # we won't trust the other end to set this properly
    $request->{errors_to}={ kernel=>$heap->{remote_kernel},
                            session=>'IKC',
                            state=>'remote_error',
                          };
    # just in case
    $request->{call}->{kernel}||=$heap->{kernel_name};

    # call the Responder channel to process
    # hmmm.... i wonder if this could be stream-lined into a direct call
    $kernel->call('IKC', 'request', $request);
    return;
}

#----------------------------------------------------
# Local kernel is sending a request to a foreign kernel
sub channel_send
{
    my ($heap, $request)=@_[HEAP, ARG0];

    DEBUG && warn "$$: Sending data...\n";
        # add our name so the foreign channel can find us
        # TODO should we do this?  or should the other end do this?
    $request->{rsvp}->{kernel}||=$heap->{kernel_name}
            if $request->{rsvp};

    $heap->{'wheel_client'}->put($request);
    return 1;
}

#----------------------------------------------------
# Local kernel things it's time to close down the channel
sub channel_close
{
    my ($heap)=$_[HEAP];
    DEBUG && warn "$$: channel_close\n";
    delete $heap->{'wheel_client'};
}

###########################################################################


1;
__END__


=head1 NAME

POE::Component::IKC::Channel - POE Inter-Kernel Communication I/O session

=head1 SYNOPSIS

    use POE;
    use POE::Component::IKC::Channel;
    create_ikc_channel($handle, $name, $on_connect, $subscribe);

=head1 DESCRIPTION

This module implements an POE IKC I/O.  
When a new connection
is established, C<IKC::Server> and C<IKC::Client> create an 
C<IKC::Channel> to handle the I/O.  

=head1 EXPORTED FUNCTIONS

=item C<create_ikc_channel($handle, $kernel_name, $on_connect)>

This function initiates all the work of connecting to a IKC connection
channel.

IKC communication happens in 2 phases : negociation phase and normal phase.

The negociation phase uses C<Filter::Line> and is used to exchange various
parameters between kernels (example : kernel names, what type of freeze/thaw
to use, etc).  After negociation, C<IKC::Channel> switches to a
C<Filter::Reference> and creates a C<IKC::Responder>, if needed.  After
this, the channel forwards reads and writes between C<Wheel::ReadWrite> and
the Responder.  

C<IKC::Channel> is also in charge of cleaning up kernel names when
the foreign kernel disconnects.

=over 3

=item C<$handle>

The perl handle we should hand to C<Wheel::ReadWrite::new>.

=item C<$kernel_name>

The name of the local kernel.  B<This is a stop-gap until event naming
has been resolved>.

=item C<$on_connect>

Code ref that is called when the negociation phase has terminated.  Normaly,
you would use this to start the sessions that post events to foreign
kernels.

=item C<$subscribe>

Array ref of specifiers (either foreign sessions, or foreign states) that
you want to subscribe to.  $on_connect will only be called if you can
subscribe to all those specifiers.  If it can't, it will die().

=back

=head1 BUGS

=head1 AUTHOR

Philip Gwyn, <fil@pied.nu>

=head1 SEE ALSO

L<POE>, L<POE::Component::IKC::Server>, L<POE::Component::IKC::Client>,
L<POE::Component::IKC::Responder>


=cut
