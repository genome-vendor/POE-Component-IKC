# $Id: Proxy.pm 168 2006-11-16 19:57:48Z fil $
package POE::Component::IKC::Proxy;

##############################################################################
# $Id: Proxy.pm 168 2006-11-16 19:57:48Z fil $
# Copyright 1999,2002,2004 Philip Gwyn.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# Contributed portions of IKC may be copyright by their respective
# contributors.  

use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $ikc_kernel);
use Carp;
use Data::Dumper;

use POE qw(Session);
use POE::Component::IKC::Specifier;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(create_ikc_proxy);
$VERSION = '0.1903';

sub DEBUG { 0 }

sub create_ikc_proxy
{
    __PACKAGE__->spawn(@_);
}

sub spawn
{
    my($package, $r_kernel, $r_session, $monitor_start, $monitor_stop)=@_;

    my $name=specifier_name({kernel=>$r_kernel, session=>$r_session});
    my $t=$poe_kernel->alias_resolve($name);

    if($t) {
        # why is this commented out?
       # $poe_kernel->call($t, '_add_callback', $r_kernel, $r_session);
    } 
    else {
        POE::Session->create( 
            package_states => [
                        $package => 
                            [qw(
                                _start _stop _delete _default 
                                _shutdown _add_callback
                            )],
                    ],
            args=> [$name, $r_kernel, $r_session, 
                            $monitor_start, $monitor_stop]
                    );
    }
}

sub _start
{
    my($kernel, $heap, $name, $r_kernel, $r_session, $monitor_start, 
                                                     $monitor_stop)=
                    @_[KERNEL, HEAP, ARG0, ARG1, ARG2, ARG3, ARG4];
    
    $heap->{name}=$name;
    $heap->{monitor_stop}=$monitor_stop;
    $heap->{callback}=[];
    _add_callback($heap, $r_kernel, $r_session);

    DEBUG && warn "Proxy for $name ($r_session) created\n";
    $kernel->alias_set($name);
    $kernel->alias_set($r_session);

    # monitor for shutdown events.  
    # this is the best way to get IKC::Responder to tell us about the 
    # shutdown
    $kernel->post(IKC=>'monitor', '*', {shutdown=>'_shutdown'});

    &$monitor_start;
}

sub _shutdown
{
    my($kernel, $heap)=@_[KERNEL, HEAP];
    $kernel->alias_remove($heap->{name});
    my $spec=specifier_parse($heap->{name});
    $kernel->alias_remove($spec->{session}) if $spec;
}

sub _add_callback
{
    my($heap, $r_k, $r_s)=@_[HEAP, ARG0, ARG1];
    ($heap, $r_k, $r_s)=@_ if not $heap;
    
    push @{$heap->{callback}},  { kernel=>$r_k, 
                                  session=>$r_s, 
                                  state=>'IKC:proxy'
                                };
}

sub _delete
{
    my($kernel, $heap)=@_[KERNEL, HEAP];
    $kernel->alias_remove($heap->{name});    
}

sub _stop
{
    my($kernel, $heap)=@_[KERNEL, HEAP];
    DEBUG && warn "Proxy for $heap->{name} deleted\n";
    &{$heap->{monitor_stop}};
}



sub _default
{
    my($kernel, $heap, $state, $args, $sender)=
                    @_[KERNEL, HEAP, ARG0, ARG1, SENDER];
    return if $state =~ /^_/;

    # use Data::Dumper;
    # warn "_default args=", Dumper $args;
    if(not $heap->{callback})
    {
        warn "Attempt to respond to a callback with $state\n";
        return;
    }

    DEBUG && warn "Proxy $heap->{name}/$state posted.\n";
    # use Data::Dumper;
    # warn "_default args=", Dumper $args;
    my $ARG = [$state, [@$args]];
    foreach my $r_state (@{$heap->{callback}}) {
        # warn "_default ARG=", Dumper $ARG;
        $kernel->call('IKC', 'post2', $r_state, $sender, $ARG);
    }
    return;
}

1;

__END__

=head1 NAME

POE::Component::IKC::Proxy - POE IKC proxy session

=head1 SYNOPSIS

=head1 DESCRIPTION

Used by IKC::Responder to create proxy sessions when you subscribe to a
remote session.  You probably don't want to use it directly.

=head1 AUTHOR

Philip Gwyn, <perl-ikc at pied.nu>

=head1 SEE ALSO

L<POE>, L<POE::Component::IKC>

=cut


$Log$
Revision 1.13.2.1  2006/11/01 18:30:54  fil
Moved to version 0.1902

Revision 1.13  2005/09/14 02:02:54  fil
Version from IKC/Responder
Now use Session->create, not ->new
Improved formating
DEBUG warnings, not print
Proxy uses call() to work around the @$etc=() bug in POE

Revision 1.12  2005/08/04 22:01:30  fil
Fixed Channel shutdown code
Documented how to shutdown a channel
Freezer now checks for nfreeze first
Moved to version 0.18
Added USR1 (non-verbose kernel state dumping) to Server
Improved Server kernel state dumping

Revision 1.11  2005/06/09 04:20:55  fil
Reconciled
Added check to put() to a closed wheel in Channel

Revision 1.10  2004/05/13 19:51:21  fil
Moved to signal_handled

Revision 1.9  2002/05/02 19:35:54  fil
Updated Chanages.
Merged alias listing for publish/subtract
Moved version

Revision 1.8  2002/05/02 19:00:32  fil
Fixed inform_monitor comming from IKC::Proxy/_stop.  We can't post()
from _stop, so method call is turned into ->call().

Revision 1.7  2001/09/06 23:13:42  fil
Added doco for Responder->spawn
Responder->spawn always returns true so that JAAS's factory doesn't complain

Revision 1.6  2001/07/24 20:45:54  fil
Fixed some win32 things like WSAEAFNOSUPPORT
Added more tests to t/20_clientlite.t

Revision 1.5  2001/07/13 06:59:45  fil
Froze to 0.13

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
