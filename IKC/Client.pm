package POE::Component::IKC::Client;

############################################################
# $Id: Client.pm,v 1.7 2001/07/13 06:59:45 fil Exp $
# Based on refserver.perl
# Contributed by Artur Bergman <artur@vogon-solutions.com>
# Revised for 0.06 by Rocco Caputo <troc@netrus.net>
# Turned into a module by Philp Gwyn <fil@pied.nu>
#
# Copyright 1999,2000,2001 Philip Gwyn.  All rights reserved.
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
use Carp;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(create_ikc_client);
$VERSION = '0.13';

sub DEBUG { 0 }


###############################################################################
#----------------------------------------------------
# This is just a convenient way to create servers.  To be useful in
# multi-server situations, it probably should accept a bind address
# and port.
sub create_ikc_client
{
    my(%parms)=@_;
    $parms{package}||=__PACKAGE__;
    $parms{on_connect}||=sub{};         # would be silly for this to be blank
                                        # 2001/04 not any more
    if($parms{unix}) {
    } else {
        $parms{ip}||='localhost';           
        $parms{port}||=903;                 # POE! (almost :)
    }
    $parms{name}||="Client$$";
    $parms{subscribe}||=[];
    my $defaults;
    if($parms{serializers}) {               # use ones provided
                                            # make sure it's an arrayref
        $parms{serializers}=[$parms{serializers}] 
                                    unless ref $parms{serializers};
    } 
    else {                                  # use default ones
        $defaults=1;                        # but don't gripe
        $parms{serializers}=[qw(Storable FreezeThaw
                                POE::Component::IKC::Freezer)];
    }

    # make sure the serializers are real 
    my @keep;
    foreach my $p (@{$parms{serializers}}) {
        unless(_package_exists($p)) {
            my $q=$p;
            $q=~s(::)(/)g;
            DEBUG and warn "Trying to load $p ($q)\n";
            eval {require "$q.pm"; import $p ();};
            warn $@ if not $defaults and $@;
        }
        next unless _package_exists($p);
        push @keep, $p;
        DEBUG and warn "Using $p as a serializer\n";
    }
    $parms{serializers}=\@keep;

    new POE::Session( $parms{package}=>
                [qw(_start _stop error connected)], [\%parms]);
}

sub spawn
{
    my($package, %params)=@_;
    $params{package}=$package;
    create_ikc_client(%params);
}

sub _package_exists
{
    my($package)=@_;
    my $symtable=$::{"main::"};
    foreach my $p (split /::/, $package) {
        return unless exists $symtable->{"$p\::"};
        $symtable=$symtable->{"$p\::"};
    }
    return 1;
}

#----------------------------------------------------
# Accept POE's standard _start event, and set up the listening socket
# factory.

sub _start {
    my($heap, $parms) = @_[HEAP, ARG0];

    DEBUG && print "Client starting.\n";
    my %wheel_p=(
        SuccessState   => 'connected',    # generating this event on connection
        FailureState   => 'error'         # generating this event on error
    );
                                        # create a socket factory
    if($parms->{unix}) {
        $wheel_p{SocketDomain}=AF_UNIX;
        $wheel_p{RemoteAddress}=$parms->{unix};
#        $heap->{remote_name}="unix:$parms->{unix}";
#        $heap->{remote_name}=~s/[^-:.\w]+/_/g;
        $heap->{unix}=$parms->{unix};
    } else {
        $wheel_p{RemotePort}=$parms->{port};
        $wheel_p{RemoteAddress}=$parms->{ip};

        $heap->{remote_name}="$parms->{ip}:$parms->{port}";
    }
    $heap->{wheel} = new POE::Wheel::SocketFactory(%wheel_p);
    $heap->{on_connect}=$parms->{on_connect};
    $heap->{name}=$parms->{name};
    $heap->{subscribe}=$parms->{subscribe};
    $heap->{aliases}=$parms->{aliases};
    $heap->{serializers}=$parms->{serializers};
}

#----------------------------------------------------
# Log server errors, but don't stop listening for connections.  If the
# error occurs while initializing the factory's listening socket, it
# will exit anyway.

sub error 
{
    my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
    DEBUG && print "Client encountered $operation error $errnum: $errstr\n";
    delete $heap->{wheel};
}

#----------------------------------------------------
# The socket factory invokes this state to take care of accepted
# connections.

sub connected
{
    my ($heap, $handle, $addr, $port) = @_[HEAP, ARG0, ARG1, ARG2];
    DEBUG && print "Client connected\n"; 


                        # give the connection to a channel
    create_ikc_channel($handle, 
                        @{$heap}{qw(name on_connect subscribe
                                    remote_name unix aliases serializers)});
    delete @{$heap}{qw(name on_connect subscribe remote_name wheel aliases
                        serializers)};
    
}

sub _stop
{
#    warn "$_[HEAP] client _stop\n";
}

1;
__END__
# Below is the stub of documentation for your module. You better edit it!

=head1 NAME

POE::Component::IKC::Client - POE Inter-Kernel Communication client

=head1 SYNOPSIS

    use POE;
    use POE::Component::IKC::Client;
    create_ikc_client(
        ip=>$ip, 
        port=>$port,
        name=>"Client$$",
        on_connect=>\&create_sessions,
        subscribe=>[qw(poe:/*/timserver)],);
    ...
    $poe_kernel->run();

=head1 DESCRIPTION

This module implements an POE IKC client.  An IKC client attempts to connect
to a IKC server.  If successful, it negociates certain connection
parameters.  After this, the POE server and client are pretty much
identical.

=head1 EXPORTED FUNCTIONS

=item C<create_ikc_client>

This function initiates all the work of connecting to an IKC server.
Parameters are :

=over 4

=item C<ip>

Address to connect to.  Can be a doted-quad ('127.0.0.1') or a host name
('foo.pied.nu').  Defaults to '127.0.0.1', aka INADDR_LOOPBACK.

=item C<port>

Port to connect to.  Can be numeric (80) or a service ('http').

=item C<unix>

Path to unix-domain socket that the server is listening on.

=item C<name>

Local kernel name.  This is how we shall "advertise" ourself to foreign
kernels. It acts as a "kernel alias".  This parameter is temporary, pending
the addition of true kernel names in the POE core.

=item C<aliases>

Arrayref of even more aliases for this kernel.  Fun Fun Fun!

=item C<on_connect>

Code ref that is called when the connection has been made to the foreign 
kernel.  Normaly, you would use this to start the sessions that post events
to foreign kernels.  DEPRECATED.  Please use the IKC/monitor stuff.  See
L<POE::Component::IKC::Responder>.

=item C<subscribe>

Array ref of specifiers (either foreign sessions, or foreign states) that
you want to subscribe to.  on_connect will only be called when IKC has
managed to subscribe to all specifiers.  If it can't, it will die().  YOW
that sucks.  C<monitor> will save us all.

=item C<serializers>

Arrayref or scalar of the packages that you want to use for data
serialization.  First IKC tries to load each package.  Then, when connecting
to a server, it asks the server about each one until the server agrees to a
serializer that works on its side.

A serializer package requires 2 functions : freeze (or nfreeze) and thaw. 
See C<POE::Filter::Reference>.

The default is C<[qw(Storable FreezeThaw
POE::Component::IKC::Freezer)]>.  C<Storable> and C<FreezeThaw> are
modules in C on CPAN.  They are much much much faster then IKC's built-in
serializer C<POE::Component::IKC::Freezer>.  This serializer uses
C<Data::Dumper> and C<eval $code> to get the deed done.  There is an obvious
security problem here.  However, it has the advantage of being pure Perl and
all modules come with the core Perl distribution.

It should be noted that you should have the same version of C<Storable> on
both sides, because some versions aren't mutually compatible.

=back

=head1 BUGS

=head1 AUTHOR

Philip Gwyn, <perl-ikc at pied.nu>

=head1 SEE ALSO

L<POE>, L<POE::Component::IKC::Server>, L<POE::Component::IKC::Responder>.

=cut

