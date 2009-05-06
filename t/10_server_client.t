#!/usr/bin/perl -w
use strict;
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

use Test::More tests => 26;

sub POE::Kernel::ASSERT_EVENTS { 1 }

use POE::Component::IKC::Server;
use POE::Component::IKC::Channel;
use POE::Component::IKC::Client;
use POE qw(Kernel);

pass( "loaded" );

######################### End of black magic.
sub DEBUG () { 0 }

my $Q=2;
my %OK;
my $WIN32=1 if $^O eq 'MSWin32';


DEBUG and print "Starting servers...\n";
unless($WIN32) {
    POE::Component::IKC::Server->spawn(
        unix=>($ENV{TMPDIR}||$ENV{TEMP}||'/tmp').'/IKC-test.pl',
        name=>'Unix',
    );
}

my $port = POE::Component::IKC::Server->spawn(
        port=>0,
        name=>'Inet',
        aliases=>[qw(Ikc)],
    );

ok( $port, "Got the port number" ) or die;

Test::Server->spawn( $port );

$poe_kernel->run();

pass( "Sane shutdown" );

############################################################################
package Test::Server;
use strict;
use Config;
use POE::Session;

BEGIN {
    *DEBUG=\&::DEBUG;
}

###########################################################
sub spawn
{
    my($package, $port )=@_;
    POE::Session->create(
        args=>[$port],
        package_states=>[
            $package=>[qw(_start _stop posted called method
                        unix_register unix_unregister
                        inet_register inet_unregister
                        ikc_register ikc_unregister
                        done shutdown do_child timeout
                        sig_child
                        )],
        ],
    );
}

###########################################################
sub _start
{
    my($kernel, $heap, $port)=@_[KERNEL, HEAP, ARG0];
    DEBUG and warn "Server: _start\n";
    ::pass( '_start' );

    $kernel->alias_set('test');
    $kernel->call(IKC=>'publish',  test=>[qw(posted called method done)]);

    $heap->{port} = $port;

    my $published=$kernel->call(IKC=>'published', 'test');
#    die Denter $published;
    ::ok( (ref $published eq 'ARRAY' and @$published==4), "Published 4 events" );

    $published=$kernel->call(IKC=>'published');
    ::ok((ref $published eq 'HASH' and 2==keys %$published), "2 sessions published something");

    unless($WIN32) {
        $kernel->post(IKC=>'monitor', 'UnixClient'=>{
            register=>'unix_register',
            unregister=>'unix_unregister'
        });
    }
    $kernel->post(IKC=>'monitor', 'InetClient'=>{
            register=>'inet_register',
            unregister=>'inet_unregister'
        });
    $kernel->post(IKC=>'monitor', 'IkcClient'=>{
            register=>'ikc_register',
            unregister=>'ikc_unregister'
        });
    $kernel->post(IKC=>'monitor', '*'=>{shutdown=>'shutdown'});

    unless($WIN32) {
        $kernel->yield(do_child=>'unix');
    } else {
        SKIP: {
            ::skip( "win32 doesn't have UNIX domain sockets", 6 );
        }
        $kernel->yield(do_child=>'inet');
    }
}

###########################################################
sub do_child
{
    my($kernel, $heap, $type)=@_[KERNEL, HEAP, ARG0];
    my $pid=fork();
    die "Can't fork: $!\n" unless defined $pid;
    if($pid) {          # parent
        $kernel->sig_child( $pid => 'sig_child' );
        $kernel->delay(timeout=>60);
        return;
    }
    my $exec="$Config{perlpath} -I./blib/arch -I./blib/lib -I$Config{archlib} -I$Config{privlib} test-client $type $heap->{port}";
    DEBUG and warn "Running $exec";
    exec $exec;
    die "Couldn't exec $exec: $!\n";
}

sub sig_child
{
    return;
}


###########################################################
sub _stop
{
    my($kernel, $heap)=@_[KERNEL, HEAP, ARG0];
    DEBUG and warn "Server: _stop ($$)\n";
    ::pass('_stop');
}

###########################################################
sub posted
{
    my($kernel, $heap, $type)=@_[KERNEL, HEAP, ARG0];
    DEBUG and warn "Server: posted $heap->{q}\n";
    # 6, 12, 18
    ::is($type, 'posted', 'posted');
}

###########################################################
sub called
{
    my($kernel, $heap, $type)=@_[KERNEL, HEAP, ARG0];
    DEBUG and warn "Server: called $heap->{q}\n";
    # 7, 13, 19
    ::is($type, 'called', 'called');
}

###########################################################
sub method
{
    my($kernel, $heap, $sender, $type)=@_[KERNEL, HEAP, SENDER, ARG0];
    $type = $type->{type} if ref $type;
    DEBUG and 
        warn "Server: method type=$type q=$heap->{q}\n";
    # 8, 14, 20
    ::is($type, 'method', 'method');
    $kernel->post($sender, 'YOW');
}




###########################################################
sub done
{
    my($kernel, $heap)=@_[KERNEL, HEAP];
    # 9, 15, 21
    DEBUG and warn "Server: done\n";
    ::pass( 'done' );
}






###########################################################
sub unix_register
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: unix_register\n";
    ::is($name, 'UnixClient', 'UnixClient');
}

###########################################################
sub unix_unregister
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: unix_unregister\n";
    ::is($name, 'UnixClient', 'UnixClient');
    $kernel->yield(do_child=>'inet');
}

###########################################################
sub inet_register
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: inet_register\n";
    ::is($name, 'InetClient', 'InetClient');
}

###########################################################
sub inet_unregister
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: inet_unregister ($name)\n";
    ::is($name, 'InetClient', 'InetClient');
    $kernel->delay('timeout');
    $kernel->yield(do_child=>"ikc");
}


###########################################################
sub ikc_register
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: ikc_register\n";
    ::is( $name, 'IkcClient' , 'IkcClient' );
}

###########################################################
sub ikc_unregister
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: ikc_unregister ($name)\n";
    ::is($name, 'IkcClient', 'IkcClient');
    $kernel->delay('timeout');
    $kernel->post(IKC=>'shutdown');
}


###########################################################
sub shutdown
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    $kernel->alias_remove('test');
    DEBUG and warn "Server: shutdown\n";
    ::pass('shutdown');
}

###########################################################
sub timeout
{
    my($kernel)=$_[KERNEL];
    warn "Server: Timedout waiting for child process.\n";
    $kernel->post(IKC=>'shutdown');
}

