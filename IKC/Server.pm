package POE::Component::IKC::Server;

############################################################
# $Id$
# Based on refserver.perl and preforkedserver.perl
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
use POE qw(Wheel::ListenAccept Wheel::SocketFactory);
use POE::Component::IKC::Channel;
use POE::Component::IKC::Responder;

use POSIX qw(ECHILD EAGAIN WNOHANG);

require Exporter;

@ISA = qw(Exporter);
@EXPORT = qw(create_ikc_server);
$VERSION = '0.09';

sub DEBUG { 0 }
sub DEBUG_USR2 { 1 }

###############################################################################
#----------------------------------------------------
# This is just a convenient way to create servers.  To be useful in
# multi-server situations, it probably should accept a bind address
# and port.
sub create_ikc_server
{
    my(%params)=@_;
    $params{ip}||='0.0.0.0';            # INET_ANY
    $params{port}||=603;                # POE! (almost :)
    create_ikc_responder();
    POE::Session->new( 
                    _start   => \&server_start,
                    _stop    => \&server_stop,
                    error    => \&server_error,
                    'accept' => \&server_accept,
                    'other_signal' => \&other_signal,
                    'signal' => \&server_signal,
                    'fork'   => \&server_fork,
                    'retry'  => \&server_retry,
                    'waste_time' => \&server_waste,
                    'babysit' => \&server_babysit,
                    [\%params],
                  );
}

#----------------------------------------------------
# NOTE : THIS IS POORLY BEHAVED CODE
sub _select_define
{
    my($heap, $on)=@_;

    my $state;
    if($on) {
        $state=$heap->{wheel}->{'state_accept'};
        
        unless(defined $state) {
            die "No 'state_accept' in $heap->{wheel}, possible redefinition of POE internals or failure to bind to port.\n";
        }
    }
    my $c=0;
    foreach my $hndl (qw(socket_handle)) {
        next unless defined $heap->{wheel}->{$hndl};
        $poe_kernel->select_read($heap->{wheel}->{$hndl}, $state);
        $c++;
    }
    die "No socket_handle in $heap->{wheel}, possible redefinition of POE internals.\n" unless $c;
    return;
}

#----------------------------------------------------
# Accept POE's standard _start event, and set up the listening socket
# factory.

sub server_start
{
    my($heap, $params, $kernel) = @_[HEAP, ARG0, KERNEL];

    DEBUG && print "$$: Server starting $params->{ip}:$params->{port}.\n";
                                        # create a socket factory
    $heap->{wheel} = new POE::Wheel::SocketFactory
    ( BindPort       => $params->{port},
      BindAddress    => $params->{ip},
      Reuse          => 'yes',          # and allow immediate reuse of the port
      SuccessState   => 'accept',       # generating this event on connection
      FailureState   => 'error'         # generating this event on error
    );
    $heap->{name}=$params->{name};

    return unless $params->{processes};

    # Delete the SocketFactory's read select in the parent
    # We don't ever want the parent to accept a connection
    # Children put the state back in place after the fork
    _select_define($heap, 0);

    $kernel->sig('CHLD', 'signal');
    $kernel->sig('INT', 'signal');
    DEBUG_USR2 and $kernel->sig('USR2', 'other_signal');
                                        # keep track of children
    $heap->{children} = {};
    $heap->{'failed forks'} = 0;
    $heap->{verbose}=$params->{verbose}||0;
    $heap->{"max connections"}=$params->{connections}||1;
                                        # change behavior for children
    $heap->{'is a child'} = 0;
    foreach (2..$params->{processes}) { # fork the initial set of children
        $kernel->yield('fork');
    }
    $kernel->yield('waste_time');    
    $kernel->yield('babysit')           if $params->{babysit};    
    return;
}

#------------------------------------------------------------------------------
# This event keeps this POE kernel alive
sub server_waste
{
    my($kernel, $heap)=@_[KERNEL, HEAP];
    return if $heap->{'is a child'};

    if($heap->{'die'}) {
        DEBUG and warn "$$: Orderly shutdown\n";
    } else {
        $kernel->delay('waste_time', 60);
    }
    return;
}
    
#------------------------------------------------------------------------------
# Babysit the child processes
sub server_babysit
{
    my($kernel, $heap)=@_[KERNEL, HEAP];

    return if $heap->{'die'} or             # don't scan if we are dieing
              $heap->{'is a child'};        # or if we are a child

    my @children=keys %{$heap->{children}};
    DEBUG and warn  "$$: Scanning children ", join(", ", sort @children), "\n";
    my(%missing, $state, $stateT);
    foreach my $pid (@children) {
        unless(open STATUS, "/proc/$pid/status") {
            warn "$$: Unable to open /proc/$pid/status!  Is the child missing: $!\n";
            $missing{$pid}=1;
        } else {
            undef($state);
            undef($stateT);
            while(<STATUS>) {
                next unless /^State:\s*(\w)\s*\((\w+)\)/;
                ($state, $stateT)=($1,$2);
                last;
            }
            close STATUS or warn $!;

            if(defined $state) {
                if($state eq 'Z') {
                    my $t=waitpid($pid, POSIX::WNOHANG());
                    if($t==$pid) {
                        # process was reaped, now fake a SIGCHLD
                        $kernel->yield('signal', 'CHLD', $pid, $?);
                        DEBUG and warn "$$: Faking a CHLD for $pid\n";            
                    } else {
                        $heap->{verbose} and warn "$$: $pid is a $state ($stateT) and couldn't be reaped.\n";
                        $missing{$pid}=1;
                    }
                } elsif($state eq 'R' or $state eq 'S') {
                    # do nothing
                } else {
                    $heap->{verbose} and warn "$$: $pid has unknown state $state ($stateT)\n";
                }
            } else {
                $heap->{verbose} and warn "$$: Can't find status for $pid!\n";
                $missing{$pid}=1;
            }
        }
    }

    foreach my $pid (keys %missing) {
        $kernel->yield('signal', 'CHLD', $pid, 0);
        DEBUG and warn "$$: Faking a CHLD for $pid MIA\n";            
    }

    $kernel->delay('babysit', 60);
    return;
}

#------------------------------------------------------------------------------
# Accept POE's standard _stop event, and stop all the children, too.
# The 'children' hash is maintained in the 'fork' and 'signal'
# handlers.  It's empty for children.

sub server_stop 
{
    my $heap = $_[HEAP];
                                        # kill the child servers
    if($heap->{children}) {
        foreach (keys %{$heap->{children}}) {
            DEBUG && print "$$: server is killing child $_ ...\n";
            kill 2, $_ or warn "$$: $_ $!\n";
        }
    }
    DEBUG && print "$$: server is stopped\n";
}

#----------------------------------------------------
# Log server errors, but don't stop listening for connections.  If the
# error occurs while initializing the factory's listening socket, it
# will exit anyway.

sub server_error 
{
    my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
    warn __PACKAGE__, " encountered $operation error $errnum: $errstr\n";
    if($errnum==98) {
        $heap->{'die'}=1;
    }
}

#----------------------------------------------------
# The socket factory invokes this state to take care of accepted
# connections.

sub server_accept 
{
    my ($heap, $kernel, $handle, $peer_host, $peer_port) = 
            @_[HEAP, KERNEL, ARG0, ARG1, ARG2];

    if(DEBUG) {
        if ($heap->{'is a child'}) {
            print "$$: Server connection from ", inet_ntoa($peer_host), 
                            ":$peer_port (Connection $heap->{connections})\n";
        } else {
            print "$$: Server connection from ", inet_ntoa($peer_host), 
                            ":$peer_port\n";
        }
    }
    if($heap->{children} and not $heap->{'is a child'}) {
        warn "Parent process received a connection: THIS SUCKS\n";
        _select_define($heap, 0);
        return;
    }
                                        # give the connection to a channel
    create_ikc_channel($handle, $heap->{name});

    return unless $heap->{children};

    if ($heap->{'is a child'}) {

        if (--$heap->{connections} < 1) {
            delete $heap->{wheel};
            $kernel->yield('_stop');
        }
    } else {
        warn "$$: Master client got a connect!  this sucks!\n";
    }
}




#------------------------------------------------------------------------------
# The server has been requested to fork, so fork already.
sub server_fork 
{
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    # children should not honor this event
    # Note that the forked POE kernel might have these events in it already
    # this is unavoidable
    if($heap->{'is a child'} or not $heap->{children} or $heap->{'die'}) {
        ## warn "$$: We are a child, why are we forking?\n";
        return;
    }

                                        # try to fork
    my $pid = fork();
                                        # did the fork fail?
    unless (defined($pid)) {
                                        # try again later, if a temporary error
        if (($! == EAGAIN) || ($! == ECHILD)) {
            $heap->{'failed forks'}++;
            $kernel->delay('retry', 1);
        }
                                        # fail permanently, if fatal
        else {
            warn "Can't fork: $!\n";
            $kernel->yield('_stop');
        }
        return;
    }
                                        # successful fork; parent keeps track
    if ($pid) {
        $heap->{children}->{$pid} = 1;
        DEBUG &&
            print( "$$: master server forked a new child.  children: (",
                    join(' ', sort keys %{$heap->{children}}), ")\n"
                 );
    }
                                        # child becomes a child server
    else {
        $heap->{verbose} and warn "$$: Created ", scalar localtime, "\n";
        $heap->{'is a child'}   = 1;        # don't allow fork
        $heap->{children}       = { };      # don't kill child processes
                                            # limit sessions, then die off
        $heap->{connections}    = $heap->{"max connections"};   

        # Create a select for the children, so that SocketFactory can
        # do it's thing
        _select_define($heap, 1);
        $kernel->sig('CHLD');
        $kernel->sig('INT');

        DEBUG && print "$$: child server has been forked\n";
    }
    return;
}


#------------------------------------------------------------------------------
# Retry failed forks.  This is invoked (after a brief delay) if the
# 'fork' state encountered a temporary error.

sub server_retry 
{
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    if($heap->{'is a child'} or not $heap->{children}) {
        warn "$$: We are a child, why are we forking?\n";
        return;
    }

    # Multiplex the delayed 'retry' event into enough 'fork' events to
    # make up for the temporary fork errors.

    for (1 .. $heap->{'failed forks'}) {
        $kernel->yield('fork');
    }
                                        # reset the failed forks counter
    $heap->{'failed forks'} = 0;
    return;
}

#------------------------------------------------------------------------------
# Process signals.  SIGCHLD causes this session to fork off a
# replacement for the lost child.  Terminal signals aren't handled, so
# the session will stop on SIGINT.  The _stop event handler takes care
# of cleanup.

sub server_signal 
{
    my ($kernel, $heap, $signal, $pid, $status) =
                @_[KERNEL, HEAP, ARG0, ARG1, ARG2];


    return if $heap->{"is a child"};

      # Some operating systems call this SIGCLD.  POE's kernel translates
      # CLD to CHLD, so developers only need to check for the one version.
    if($heap->{children} and $signal eq 'CHLD') {
                                        # if it was one of ours; fork another
        if (delete $heap->{children}->{$pid}) {
            DEBUG &&
                    print( "$$: master caught SIGCHLD for $pid.  children: (",
                                join(' ', sort keys %{$heap->{children}}), ")\n"
                        );
            $heap->{verbose} and warn "$$: Child $pid exited.\n";
            $kernel->yield('fork') unless $heap->{'die'};
        } else {
            warn "$$: CHLD for a child of someone else.\n";
        }
    }

    if($signal eq 'INT') {
        if($heap->{children}) {
            warn "$$ SIGINT\n";
            $heap->{'die'}=1;
            return 1;
        } else {
            delete $heap->{wheel};
            return 1;
        }
    }    
                                        # don't handle terminal signals
    return 0;
}


sub other_signal
{
#    return unless DEBUG;
    my ($signal, $pid) = @_[ARG0, ARG1];
    $pid||='';
    warn "$$: signal $signal $pid\n";
}


1;
__END__
# Below is the stub of documentation for your module. You better edit it!

=head1 NAME

POE::Component::IKC::Server - POE Inter-kernel Communication server

=head1 SYNOPSIS

    use POE;
    use POE::Component::IKC::Server;
    create_ikc_server(
        ip=>$ip, 
        port=>$port,
        name=>'Server',);
    ...
    $poe_kernel->run();

=head1 DESCRIPTION

This module implements a POE IKC server.  A IKC server listens for incoming
connections from IKC clients.  When a client connects, it negociates certain
connection parameters.  After this, the POE server and client are pretty much
identical.

=head1 EXPORTED FUNCTIONS

=item C<create_ikc_server>

This function initiates all the work of building the IKC server.  
Parameters are :

=over 3

=item C<ip>

Address to listen on.  Can be a doted-quad ('127.0.0.1') or a host name
('foo.pied.nu').  Defaults to '0.0.0.0', aka INADDR_ANY.

=item C<port>

Port to listen on.  Can be numeric (80) or a service ('http').

=item C<name>

Local kernel name.  This is how we shall "advertise" ourself to foreign
kernels. It acts as a "kernel alias".  This parameter is temporary, pending
the addition of true kernel names in the POE core.

=item C<processes>

Activates the pre-forking server code.  If set to a positive value, IKC will
fork processes-1 children.  IKC requests are only serviced by the children. 
Default is 1 (ie, no forking).

=item C<connections>

Number of connections a child will accept before exiting.  Currently,
connections are serviced concurrently, because there's no way to know when
we have finished a request.  Defaults to 1 (ie, one connection per
child).

=back

=head1 BUGS

Preforking is something of a hack.  In particular, you must make sure that
your sessions will permit children exiting.  This means, if you have a
delay()-loop, or event loop, children will not exit.  Once POE gets
multicast events, I'll change this behaviour. 

=head1 AUTHOR

Philip Gwyn, <fil@pied.nu>

=head1 SEE ALSO

L<POE>, L<POE::Component::IKC::Client>

=cut
