package POE::Component::IKC::Proxy;

##############################################################################
# $Id$
# Copyright 1999 Philip Gwyn.  All rights reserved.
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
$VERSION = '0.12';

sub DEBUG { 0 }

sub create_ikc_proxy
{
    my($r_kernel, $r_session)=@_;

    my $name=specifier_name({kernel=>$r_kernel, session=>$r_session});
    my $t=$poe_kernel->alias_resolve($name);

    if($t)
    {
       #  $poe_kernel->call($t, '_add_callback', $r_kernel, $r_session);
    } else
    {
        POE::Session->new(__PACKAGE__, 
                      [qw(_start _stop _delete _default _add_callback)], 
                      [$name, $r_kernel, $r_session]
                     );
    }
}

sub _start
{
    my($kernel, $heap, $name, $r_kernel, $r_session)=
                    @_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    
    $heap->{name}=$name;
    $heap->{callback}=[];
    _add_callback($heap, $r_kernel, $r_session);

    DEBUG && print "Proxy for $name created\n";
    $kernel->alias_set($name);
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
#    warn "$_[HEAP] proxy _stop\n";

    DEBUG && print "Proxy for $_[HEAP]->{name} deleted\n";
}


sub _default
{
    my($kernel, $heap, $state, $args)=@_[KERNEL, HEAP, ARG0, ARG1];
    return if $state =~ /^_/;

    if(not $heap->{callback})
    {
        warn "Attempt to respond to a callback with $state\n";
        return;
    }

    DEBUG && print "Proxy $heap->{name}/$state posted\n";
    foreach my $r_state (@{$heap->{callback}})
    {
        $kernel->post('IKC', 'post', $r_state, [$state, $args]);
    }
}

1;

