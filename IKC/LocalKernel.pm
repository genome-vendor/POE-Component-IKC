package POE::Component::IKC::LocalKernel;

############################################################
# $Id: LocalKernel.pm,v 1.5 2001/08/02 03:26:50 fil Exp $
# Copyright 1999,2001,2002 Philip Gwyn.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# Contributed portions of IKC may be copyright by their respective
# contributors.  

use strict;
use POE::Session;
use POE::Component::IKC::Responder;

sub DEBUG () { 0 }

#----------------------------------------------------
sub spawn
{
    my $package=shift;
#    my %params=@_;

    POE::Component::IKC::Responder->spawn();
    POE::Session->create( 
        package_states=>[
            $package=>[qw(_start _default shutdown send sig_INT)],
        ],
#        heap=>{%params},
    );
}

#----------------------------------------------------
sub _start
{
    my($kernel, $heap, $session)=@_[KERNEL, HEAP, SESSION];
    $kernel->sig(INT=>'sig_INT');
    $kernel->alias_set('-- Local Kernel IKC Channel --');
    
    $heap->{ref}=1;
#    $kernel->call('IKC', 'register', $kernel->ID, $heap->{aliases});
}

#----------------------------------------------------
#
sub _default
{
    my($event)=$_[STATE];
    DEBUG && warn "Unknown event $event posted to IKC::LocalKernel\n"
        if $event !~ /^_/;
    return;
}

#----------------------------------------------------
sub shutdown 
{
    my($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
    DEBUG && warn "$$: Channel will shut down.\n";
    return unless $heap->{ref};
    delete $heap->{ref};
}

#----------------------------------------------------
sub send
{
    my($kernel, $heap, $request) = @_[KERNEL, HEAP, ARG0];

    DEBUG && warn "$$: Sending data...\n";
    $request->{rsvp}->{kernel}||=$kernel->ID
            if ref($request) and $request->{rsvp};

    DEBUG && warn "$$: Recieved data...\n";
    $request->{errors_to}={ kernel=>$kernel->ID,
                            session=>'IKC',
                            state=>'remote_error',
                          };
    $request->{call}->{kernel}||=$heap->{kernel_name};
    $kernel->call('IKC', 'request', $request);
    return 1;
}

#----------------------------------------------------
sub sig_INT
{
    my($kernel, $heap) = @_[KERNEL, HEAP];
    DEBUG && warn "$$: sig_INT\n";
    $kernel->yield('shutdown');
}

1;

__DATA__

$Log: LocalKernel.pm,v $
Revision 1.5  2001/08/02 03:26:50  fil
Added documentation.

Revision 1.4  2001/07/25 21:06:08  fil
Fixed usage bug in IKC::LocalKernel

Revision 1.3  2001/07/25 20:58:10  fil
IKC::LocalKernel now uses an alias() rather then refcount to stay alive.
This way the kernel will exit normaly

Revision 1.2  2001/07/25 07:25:14  fil
Minor bug fixes.
IKC/register, IKC/retract w/o a session alias uses ALL session aliases

Revision 1.1  2001/07/25 04:01:44  fil
Fixed bug that didn't caused multiple responders to be created if you used
spawn.

Added registering of local kernels.
