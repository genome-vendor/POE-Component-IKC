package POE::Component::IKC::Server;

############################################################
# $Id: Server.pm,v 1.22 2005/09/14 02:02:54 fil Exp $
# Based on refserver.perl and preforkedserver.perl
# Contributed by Artur Bergman <artur@vogon-solutions.com>
# Revised for 0.06 by Rocco Caputo <troc@netrus.net>
# Turned into a module by Philp Gwyn <fil@pied.nu>
#
# Copyright 1999,2001,2002,2004 Philip Gwyn.  All rights reserved.
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
use POSIX qw(:errno_h);
use POSIX qw(ECHILD EAGAIN WNOHANG);

require Exporter;

@ISA = qw(Exporter);
@EXPORT = qw(create_ikc_server);
$VERSION = '0.18';

sub DEBUG { 0 }
sub DEBUG_USR2 { 1 }
BEGIN {
    # http://support.microsoft.com/support/kb/articles/Q150/5/37.asp
    eval '*WSAEAFNOSUPPORT = sub { 10047};';
    if($^O eq 'MSWin32') {
        eval '*EADDRINUSE      = sub { 10048 };';
    }
}


###############################################################################
#----------------------------------------------------
# This is just a convenient way to create servers.  To be useful in
# multi-server situations, it probably should accept a bind address
# and port.
sub create_ikc_server
{
    my(%params)=@_;
    $params{package}||=__PACKAGE__;

    unless($params{unix}) {
        $params{ip}||='0.0.0.0';            # INET_ANY
        $params{port}||=603;                # POE! (almost :)
    }

    create_ikc_responder();
    POE::Session->create(
                    package_states => [ 
                        $params{package} =>
                        [qw(
                            _start _stop error
                            accept fork retry waste_time
                            babysit rogues shutdown
                            sig_CHLD sig_INT sig_USR2 sig_USR1
                        )],
                    ],
                    args=>[\%params],
                  );
}

sub spawn
{
    my($package, %params)=@_;
    $params{package}=$package;
    create_ikc_server(%params);
}

#----------------------------------------------------
# NOTE : THIS IS POORLY BEHAVED CODE
sub _select_define
{
    my($heap, $on)=@_;
    $on||=0;

    DEBUG and 
        warn "_select_define (on=$on)";

    if($POE::VERSION >= 0.24) {
        if($on) {
            $heap->{wheel}->resume_accept
        }
        else {
            $heap->{wheel}->pause_accept
        }
        return;
    }

    # NOTE : FOR OLDER VERSIONS OF POE
    # THIS IS POORLY BEHAVED CODE
    my $state;
    my $err="possible redefinition of POE internals";
    $err="failure to bind to port" if $POE::VERSION <= 0.1005;

    if($on) {
        if(ref $heap->{wheel} eq 'HASH') {
            $state=$heap->{wheel}->{'state_accept'};
        } else {
            $state=$heap->{wheel}->[5];
        }

        unless(defined $state) {
            die "No 'state_accept' in $heap->{wheel}, $err.\n";
        }
    }

    my $c=0;
    if(ref $heap->{wheel} eq 'HASH') {
        foreach my $hndl (qw(socket_handle)) {
            next unless defined $heap->{wheel}->{$hndl};
            $poe_kernel->select_read($heap->{wheel}->{$hndl}, $state);
            $c++;
        }
    }
    else {
        $poe_kernel->select_read($heap->{wheel}->[0], $state);
        $c++;
    }
    die "No socket_handle in $heap->{wheel}, $err.\n" unless $c;
    return;
}

#----------------------------------------------------
# Accept POE's standard _start event, and set up the listening socket
# factory.

sub _start
{
    my($heap, $params, $kernel) = @_[HEAP, ARG0, KERNEL];

    # monitor for shutdown events.
    # this is the best way to get IKC::Responder to tell us about the
    # shutdown
    $kernel->post(IKC=>'monitor', '*', {shutdown=>'shutdown'});

    my $alias='unknown';
    my %wheel_p=(
        Reuse          => 'yes',        # and allow immediate reuse of the port
        SuccessEvent   => 'accept',     # generating this event on connection
        FailureEvent   => 'error'       # generating this event on error
    );
    if($params->{unix}) {
        $alias="unix:$params->{unix}";
        $wheel_p{SocketDomain}=AF_UNIX;
        $wheel_p{BindAddress}=$params->{unix};
        $heap->{unix}=$params->{unix};
        unlink $heap->{unix};           # blindly do this ?
    }
    else {
        $alias="$params->{ip}:$params->{port}";
        $wheel_p{BindPort}= $params->{port};
        $wheel_p{BindAddress}= $params->{ip};
    }
    DEBUG && warn "$$: Server starting $alias.\n";

    # +GC
    $kernel->alias_set("IKC Server $alias");

                                        # create a socket factory
    $heap->{wheel_address}=$alias;
    $heap->{wheel} = new POE::Wheel::SocketFactory (%wheel_p);
    $heap->{name}=$params->{name};
    $heap->{kernel_aliases}=$params->{aliases};

    # set up local names for kernel
    my @names=($heap->{name});
    if($heap->{kernel_aliases}) {
        if(ref $heap->{kernel_aliases}) {
            push @names, @{$heap->{kernel_aliases}};
        } else {
            push @names, $heap->{kernel_aliases};
        }
    }

    $kernel->post(IKC=>'register_local', \@names);

    return unless $params->{processes};

    # Delete the SocketFactory's read select in the parent
    # We don't ever want the parent to accept a connection
    # Children put the state back in place after the fork
    _select_define($heap, 0);

    $kernel->sig(CHLD => 'sig_CHLD');
    $kernel->sig(INT  => 'sig_INT');
    DEBUG_USR2 and $kernel->sig('USR2', 'sig_USR2');
    DEBUG_USR2 and $kernel->sig('USR1', 'sig_USR1');

                                        # keep track of children
    $heap->{children} = {};
    $heap->{'failed forks'} = 0;
    $heap->{verbose}=$params->{verbose}||0;
    $heap->{"max connections"}=$params->{connections}||1;

    $heap->{'is a child'} = 0;          # change behavior for children
    my $children=0;
    foreach (2..$params->{processes}) { # fork the initial set of children
        $kernel->yield('fork', ($_ == $params->{processes}));
        $children++;
    }

    $kernel->yield('waste_time', 60) unless $children;
    if($params->{babysit}) {
        $heap->{babysit}=$params->{babysit};
        delete($heap->{"proctable"});
        eval {
            require Proc::ProcessTable;
            $heap->{"proctable"}=new Proc::ProcessTable;
        };
        DEBUG and do {
            print "Unable to load Proc::ProcessTable: $@\n" if $@;
        };
        $kernel->yield('babysit');
    }
    return;
}

#------------------------------------------------------------------------------
# This event keeps this POE kernel alive
sub waste_time
{
    my($kernel, $heap)=@_[KERNEL, HEAP];
    return if $heap->{'is a child'};

    unless($heap->{'been told we are parent'}) {
        warn "$$: Telling everyone we are the parent\n";
        $heap->{'been told we are parent'}=1;
        $kernel->signal($kernel, '__parent');
    }
    if($heap->{'die'}) {
        DEBUG and warn "$$: Orderly shutdown\n";
    } else {
        $kernel->delay('waste_time', 60);
    }
    return;
}
    
#------------------------------------------------------------------------------
# Babysit the child processes
sub babysit
{
    my($kernel, $heap)=@_[KERNEL, HEAP];

    return if $heap->{'die'} or             # don't scan if we are dieing
              $heap->{'is a child'};        # or if we are a child

    my @children=keys %{$heap->{children}};
    $heap->{verbose} and warn  "$$: Babysiting ", scalar(@children), 
                            " children ", join(", ", sort @children), "\n";
    my %table;

    if($heap->{proctable}) {
        my $table=$heap->{proctable}->table;
        %table=map {($_->pid, $_)} @$table
    }

    my(%missing, $state, $time, %rogues, %ok);
    foreach my $pid (@children) {
        if($table{$pid}) {
            $state=$table{$pid}->state;

            if($state eq 'zombie') {
                my $t=waitpid($pid, POSIX::WNOHANG());
                if($t==$pid) {
                    # process was reaped, now fake a SIGCHLD
                    DEBUG and warn "$$: Faking a CHLD for $pid\n";            
                    $kernel->yield('sig_CHLD', 'CHLD', $pid, $?, 1);
                    $ok{$pid}=1;
                } else {
                    $heap->{verbose} and warn "$$: $pid is a $state and couldn't be reaped.\n";
                    $missing{$pid}=1;
                }
            } 
            elsif($state eq 'run') {
                $time=eval{$table{$pid}->utime + $table{$pid}->stime};
                warn $@ if $@;
                # utime and stime are Linux-only :(

                if($time and $time > 600_000) { # arbitrary limit of 10 minutes
                    $rogues{$pid}=$table{$pid};
                    # DEBUG and 
                        warn "$$: $pid hass gone rogue, time=$time ms\n";
                } else {
                    warn "$$: child $pid has utime+stime=$time ms\n";
                    $ok{$pid}=1;
                }

            } elsif($state eq 'sleep' or $state eq 'defunct') {
                $ok{$pid}=1;
                # do nothing
            } else {
                $heap->{verbose} and warn "$$: $pid has unknown state '$state'\n";
                $ok{$pid}=1;
            }
        } elsif($heap->{proctable}) {
            $heap->{verbose} and warn "$$: $pid isn't in proctable!\n";
            $missing{$pid}=1;
        } else {                        # try another means.... :/
            if(-d "/proc" and not -d "/proc/$pid") {
                DEBUG and warn "$$: Unable to stat /proc/$pid!  Is the child missing\n";
                $missing{$pid}=1;
            } elsif(not $missing{$pid}) {
                $ok{$pid}=1;
            }
        }
    }

    # if a process is MIA, we fake a death, and spawn a new child
    foreach my $pid (keys %missing) {
        $kernel->yield('sig_CHLD', 'CHLD', $pid, 0, 1);
        $heap->{verbose} and warn "$$: Faking a CHLD for $pid MIA\n";            
    }

    # we could do the same thing for rogue processes, but instead we
    # give them time to calm down

    if($heap->{rogues}) {           # processes that are %ok are now removed
                                    # from the list of rogues
        delete @{$heap->{rogues}}{keys %ok} if %ok;
    }

    if(%rogues) {
        $kernel->yield('rogues') if not $heap->{rogues};

        $heap->{rogues}||={};
        foreach my $pid (keys %rogues) {
            if($heap->{rogues}{$pid}) {
                $heap->{rogues}{$pid}{proc}=$rogues{$pid};
            } else {
                $heap->{rogues}{$pid}={proc=>$rogues{$pid}, tries=>0};
            }
        }
    }

    $kernel->delay('babysit', $heap->{babysit});
    return;
}

#------------------------------------------------------------------------------
# Deal with rogue child processes
sub rogues
{
    my($kernel, $heap)=@_[KERNEL, HEAP];

    return if $heap->{'die'} or             # don't scan if we are dieing
              $heap->{'is a child'};        # or if we are a child

                                            # make sure we have some real work
    return unless $heap->{rogues};
eval {
    if(ref($heap->{rogues}) ne 'HASH' or not keys %{$heap->{rogues}}) {
        delete $heap->{rogues};
        return;
    }

    my $signal;
    while(my($pid, $rogue)=each %{$heap->{rogues}}) {
        $signal=0;
        if($rogue->{tries} < 1) {
            $signal=2;
        } 
        elsif($rogue->{tries} < 2) {
            $signal=15;
        }
        elsif($rogue->{tries} < 3) {
            $signal=9;
        }
    
        if($signal) {
            DEBUG and warn "$$: Sending signal $signal to rogue $pid\n";
            unless($rogue->{proc}->kill($signal)) {
                warn "$$: Error sending signal $signal to $pid: $!\n";
                delete $heap->{rogues}{$pid};
            }
        } else {
            # if SIGKILL didn't work, it's beyond hope!
            $kernel->yield('sig_CHLD', 'CHLD', $pid, 0, 1);
            delete $heap->{rogues}{$pid};
            $heap->{verbose} and warn "$$: Faking a CHLD for rogue $pid\n";            
        }

        $rogue->{tries}++;
    }
    $kernel->delay('rogues', 2*$heap->{babysit});
};
    warn "$$: $@" if $@;
}

#------------------------------------------------------------------------------
# Accept POE's standard _stop event, and stop all the children, too.
# The 'children' hash is maintained in the 'fork' and 'sig_CHLD'
# handlers.  It's empty for children.

sub _stop 
{
    my($kernel, $heap) = @_[KERNEL, HEAP];

                                        # kill the child servers
    if($heap->{children}) {
        foreach (keys %{$heap->{children}}) {
            DEBUG && print "$$: server is killing child $_ ...\n";
            kill 2, $_ or warn "$$: $_ $!\n";
        }
    }
    if($heap->{unix}) {
        unlink $heap->{unix};
    }
    DEBUG && 
        warn "$$: Server $heap->{name} _stop\n";
    # DEBUG_USR2 and check_kernel($kernel, $heap->{'is a child'}, 1);
}

#------------------------------------------------------------------------------
sub shutdown
{
    my($kernel, $heap)=@_[KERNEL, HEAP];

    DEBUG and warn "$$: Server $heap->{name} shutdown\n";

    my $w=delete $heap->{wheel};      # close socket
    # WORK AROUND
    $w->DESTROY;
    if($heap->{children} and %{$heap->{children}}) {
        $kernel->delay('rogues');   # we no longer care about rogues
    }
    $kernel->delay('waste_time');   # get it OVER with
    # -GC
    $kernel->alias_remove("IKC Server $heap->{wheel_address}");
    $heap->{'die'}=1;               # prevent race conditions
}

#----------------------------------------------------
# Log server errors, but don't stop listening for connections.  If the
# error occurs while initializing the factory's listening socket, it
# will exit anyway.

sub error
{
    my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
    warn __PACKAGE__, " $$: encountered $operation error $errnum: $errstr\n";
    my $ignore;
    if($errnum==EADDRINUSE) {       # EADDRINUSE
        warn "$$: IKC Address $heap->{wheel_address} in use\n";
        $heap->{'die'}=1;
        delete $heap->{wheel};
        $ignore=1;
    } elsif($errnum==WSAEAFNOSUPPORT) {
        # Address family not supported by protocol family.
        # we get this error, yet nothing bad happens... oh well
        $ignore=1;
    }
    unless($ignore) {
        # TODO : post to monitors
        warn __PACKAGE__, " $$: encountered $operation error $errnum: $errstr\n";
    }
}

#----------------------------------------------------
# The socket factory invokes this state to take care of accepted
# connections.

sub accept 
{
    my ($heap, $kernel, $handle, $peer_host, $peer_port) = 
            @_[HEAP, KERNEL, ARG0, ARG1, ARG2];

    if(DEBUG) {
        if($peer_port) {        
            warn "$$: Server connection from ", inet_ntoa($peer_host), 
                            ":$peer_port", 
                            ($heap->{'is a child'}  ? 
                            " (Connection $heap->{connections})\n" : "\n");
        } else {
            warn "$$: Server connection over $heap->{unix}",
                            ($heap->{'is a child'}  ? 
                            " (Connection $heap->{connections})\n" : "\n");
        }
    }
    if($heap->{children} and not $heap->{'is a child'}) {
        warn "$$: Parent process received a connection: THIS SUCKS\n";
        _select_define($heap, 0);
        return;
    }

    DEBUG and warn "$$: Server kernel_aliases=", join ',', @{$heap->{kernel_aliases}||[]};

                                        # give the connection to a channel
    POE::Component::IKC::Channel->spawn(
                handle=>$handle, name=>$heap->{name},
                unix=>$heap->{unix}, aliases=>[@{$heap->{kernel_aliases}||[]}]);
        
    return unless $heap->{children};

    if ($heap->{'is a child'}) {

        if (--$heap->{connections} < 1) {
            DEBUG and 
                warn "$$: ************* Game over\n";
            $kernel->delay('waste_time');
            delete $heap->{wheel};
#            $kernel->post(IKC=>'shutdown');
#            check_kernel($kernel);
#            $kernel->yield('_stop');
        } else {
            DEBUG and 
                warn "$$: $heap->{connections} left\n";
        }
    } else {
        warn "$$: Master client got a connect!  this sucks!\n";
    }
}




#------------------------------------------------------------------------------
# The server has been requested to fork, so fork already.
sub fork 
{
    my ($kernel, $heap, $last) = @_[KERNEL, HEAP, ARG0];
    # children should not honor this event
    # Note that the forked POE kernel might have these events in it already
    # this is unavoidable
    if($heap->{'is a child'} or not $heap->{children} or $heap->{'die'}) {
        DEBUG and warn "$$: We are a child, why are we forking?\n";
        return;
    }
    my $parent=$$;
                 

    DEBUG and warn "$$: Forking a child";
                                   
    my $pid = fork();                   # try to fork
    unless (defined($pid)) {            # did the fork fail?
                                        # try again later, if a temporary error
        if (($! == EAGAIN) || ($! == ECHILD)) {
            DEBUG and warn "$$: Recoverable forking problem";
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
        $kernel->yield('waste_time') if $last;
    }
                                        # child becomes a child server
    else {
        $heap->{verbose} and warn "$$: Created ", scalar localtime, "\n";
        # Clean out stuff that the parent needs but not the children

        $heap->{'is a child'}   = 1;        # don't allow fork
        $heap->{'failed forks'} = 0;
        $heap->{children}={};               # don't kill child processes
                                            # limit sessions, then die off
        $heap->{connections}    = $heap->{"max connections"};   

        $kernel->sig('CHLD');
        $kernel->sig('INT');
        # remove the wait for babysit
        $kernel->delay('babysit') if $heap->{'babysit'};
        delete @{$heap}{qw(rogues proctable)};

        # Tell everyone we are now a child
        $kernel->signal($kernel, '__child');

        # Create a select for the children, so that SocketFactory can
        # do it's thing
        _select_define($heap, 1);

        DEBUG && print "$$: child server has been forked\n";
    }

    # remove the call
    return;
}


#------------------------------------------------------------------------------
# Retry failed forks.  This is invoked (after a brief delay) if the
# 'fork' state encountered a temporary error.

sub retry 
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
# SIGCHLD causes this session to fork off a replacement for the lost child.

sub sig_CHLD
{
    my ($kernel, $heap, $signal, $pid, $status, $fake) =
                @_[KERNEL, HEAP, ARG0, ARG1, ARG2, ARG3];

    return if $heap->{"is a child"};

    if($heap->{children}) {
                                # if it was one of ours; fork another
        if (delete $heap->{children}->{$pid}) {
            DEBUG &&
                    print( "$$: master caught SIGCHLD for $pid.  children: (",
                                join(' ', sort keys %{$heap->{children}}), ")\n"
                        );
            $heap->{verbose} and warn "$$: Child $pid ", 
                        ($fake?'is gone':'exited normaly'), ".\n";
            $kernel->yield('fork') unless $heap->{'die'};
        } elsif($fake) {
            warn "$$: Needless fake CHLD for $pid\n";
        } else {
            warn "$$: CHLD for $pid child of someone else.\n";
        }
    }
                                        # don't handle terminal signals
    return;
}

#------------------------------------------------------------------------------
# Terminal signals aren't handled, so the session will stop on SIGINT.  
# The _stop event handler takes care of cleanup.

sub sig_INT
{
    my ($kernel, $heap, $signal, $pid, $status) =
                @_[KERNEL, HEAP, ARG0, ARG1, ARG2];

    return 0 if $heap->{"is a child"};

    if($heap->{children}) {
        warn "$$ SIGINT\n";
        $heap->{'die'}=1;
        $kernel->delay('waste_time');   # kill this event
        $kernel->sig_handled();
    } else {
        delete $heap->{wheel};
        $kernel->sig_handled();
    }    
    # don't handle terminal signals
    return;
}

############################################################
sub check_kernel
{
    my($kernel, $child, $signal)=@_;
    if(ref $kernel) {
        # 2 = KR_HANDLES
        # 7 = KR_EVENTS
        # 8 = KR_ALARMS (NO MORE!)
        # 12 = KR_EXTRA_REFS

        # 0 = HND_HANDLE
        warn( "$$: ,----- Kernel Activity -----\n",  
              "$$: | States : ", scalar(@{$kernel->[7]}), " ",
                            join( ', ', map {$_->[0]->ID."/$_->[2]"} 
                                        @{$kernel->[7]}), "\n",
#              "$$: | Alarms : ", scalar(@{$kernel->[8]}), "\n",
              "$$: | Files  : ", scalar(keys(%{$kernel->[2]})), "\n",
              "$$: |   `--> : ", join( ', ',
                               sort { $a <=> $b }
                               map { fileno($_->[0]) }
                               values(%{$kernel->[2]})
                             ),   "\n",
              "$$: | Extra  : ${$kernel->[12]}\n",
              "$$: `---------------------------\n",
         );
#        if($child) {
#            foreach my $q (@{$kernel->[8]}) {
#                warn "************ Alarm for ", join '/', @{$q->[0][2]{$q->[2]}};
#            }
#        }
    } else {
        warn "$kernel isn't a reference";
    }
}

############################################################
sub __peek
{
    my($verbose)=@_;
    eval {
        require POE::API::Peek;
    };
    if($@) {
        DEBUG and warn "Failed to load POE::API::Peek: $@";
        return;
    }
    my $api=POE::API::Peek->new();
    my @queue = $api->event_queue_dump();
    
    my $ret = "Event Queue:\n";
  
    foreach my $item (@queue) {
        $ret .= "\t* ID: ". $item->{ID}." - Index: ".$item->{index}."\n";
        $ret .= "\t\tPriority: ".$item->{priority}."\n";
        $ret .= "\t\tEvent: ".$item->{event}."\n";

        if($verbose) {
            $ret .= "\t\tSource: ".
                    $api->session_id_loggable($item->{source}).
                    "\n";
            $ret .= "\t\tDestination: ".
                    $api->session_id_loggable($item->{destination}).
                    "\n";
            $ret .= "\t\tType: ".$item->{type}."\n";
            $ret .= "\n";
        }
    }
    if($api->session_count) {
        $ret.="Keepalive " unless $verbose;
        $ret.="Sessions: \n";
        my $ses;
        foreach my $session ($api->session_list) {  
            my $ref=0;
            $ses='';

            $ses.="\tSession ".$api->session_id_loggable($session)." ($session)";

            my $refcount=$api->get_session_refcount($session);
            $ses.="\n\t\tref count: $refcount\n";

            my $q=$api->get_session_extref_count($session);
            $ref += $q;
            $ses.="\t\textref count: $q\n" if $q;

            my $hc=$api->session_handle_count($session);
            $ref += $hc;
            $ses.="\t\thandle count: $q [keepalive]\n" if $hc;

            my @aliases=$api->session_alias_list($session);
            $ref += @aliases;
            $q=join ',', @aliases;
            $ses.="\t\tAliases: $q\n" if $q;

            my @children = $api->get_session_children($session);
            if(@children) {
                $ref += @children;
                $q = join ',', map {$api->session_id_loggable($_)} @children;
                $ses.="\t\tChildren: $q\n";
            }

            if($refcount != $ref) {
                $ses.="\t\tReference: refcount=$refcount counted=$ref [keepalive]\n";
            }
            if($hc or $verbose or $refcount != $ref) {
                $ret.=$ses;
            }
        }
    }
    $ret.="\n";

    warn "$$: $ret";
    return 1;
}


sub sig_USR2
{
#    return unless DEBUG;
    my ($kernel, $heap, $signal, $pid) = @_[KERNEL, HEAP, ARG0, ARG1];
    $pid||='';
    warn "$$: signal $signal $pid\n";
    unless(__peek(1)) {
        check_kernel($kernel, $heap->{'is a child'}, 1);
    }
    $kernel->sig_handled();
    return;
}

sub sig_USR1
{
#    return unless DEBUG;
    my ($kernel, $heap, $signal, $pid) = @_[KERNEL, HEAP, ARG0, ARG1];
    $pid||='';
    warn "$$: signal $signal $pid\n";
    unless(__peek(0)) {
        check_kernel($kernel, $heap->{'is a child'}, 0);
    }
    $kernel->sig_handled();
    return;
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

=item C<unix>

Path to the unix-socket to listen on.  Note: this path is unlinked before 
socket is attempted!  Buyer beware.

=item C<name>

Local kernel name.  This is how we shall "advertise" ourself to foreign
kernels. It acts as a "kernel alias".  This parameter is temporary, pending
the addition of true kernel names in the POE core.  This name, and all
aliases will be registered with the responder so that you can post to them
as if they were remote.

=item C<aliases>

Arrayref of even more aliases for this kernel.  Fun Fun Fun!


=item C<verbose>

Print extra information to STDERR if true.  This allows you to see what
is going on and potentially trace down problems and stuff.

=item C<processes>

Activates the pre-forking server code.  If set to a positive value, IKC will
fork processes-1 children.  IKC requests are only serviced by the children. 
Default is 1 (ie, no forking).

=item C<babysit>

Time, in seconds, between invocations of the babysitter event.

=item C<connections>

Number of connections a child will accept before exiting.  Currently,
connections are serviced concurrently, because there's no way to know when
we have finished a request.  Defaults to 1 (ie, one connection per
child).

=back

=head1 EVENTS

=item shutdown

This event causes the server to close it's socket and skiddadle on down the
road.  Normally it is only posted from IKC::Responder.

=head1 BUGS

Preforking is something of a hack.  In particular, you must make sure that
your sessions will permit children exiting.  This means, if you have a
delay()-loop, or event loop, children will not exit.  Once POE gets
multicast events, I'll change this behaviour. 

=head1 AUTHOR

Philip Gwyn, <perl-ikc at pied.nu>

=head1 SEE ALSO

L<POE>, L<POE::Component::IKC::Client>

=cut
