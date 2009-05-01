#!/usr/bin/perl -w
use strict;
use warnings;

use Test::More tests => 30;

sub POE::Kernel::ASSERT_EVENTS { 1 }

use POE::Component::IKC::Server;
use POE::Component::IKC::Channel;
use POE::Component::IKC::Client;
use POE qw(Kernel);

pass( "loaded" );

sub DEBUG () { 0 }


DEBUG and print "Starting servers...\n";
POE::Component::IKC::Server->spawn(
        port        => 1338,
        name        => 'Inet',
        aliases     => [qw(Ikc)],
        concurrency => 2
    );

Test::Runner->spawn();

$poe_kernel->run();

pass( "Sane shutdown" );

############################################################################
package Test::Runner;
use strict;
use Config;
use POE::Session;

BEGIN {
    *ok=\&::ok;
    *DEBUG=\&::DEBUG;
}

###########################################################
sub spawn
{
    my($package)=@_;
    POE::Session->create(
#         args=>[$qref],
        package_states=>[
            $package=>[qw(_start _stop posted called method
                        inet_register inet_unregister
                        done shutdown do_child timeout
                        sig_child
                        )],
        ],
    );
}

###########################################################
sub _start
{
#    use Data::Denter;
#    die Denter "KERNEL is ". 0+KERNEL, \@_;
    my($kernel, $heap)=@_[KERNEL, HEAP, ARG0];
    DEBUG and warn "Server: _start\n";
    ::pass( '_start' );

    $kernel->alias_set('test');
    $kernel->call(IKC=>'publish',  test=>[qw(posted called method done)]);

    $kernel->post(IKC=>'monitor', '*'=>{shutdown=>'shutdown'});

    # ::diag( "Launch 5 clients" );
    foreach ( 1..5 ) {
        $kernel->yield(do_child=>'inet');
    }
}

###########################################################
sub do_child
{
    my($kernel, $type)=@_[KERNEL, ARG0];
    my $pid=fork();
    die "Can't fork: $!\n" unless defined $pid;
    if($pid) {          # parent
        $kernel->sig_child( $pid => 'sig_child' );
        $kernel->delay(timeout=>60);
        $kernel->post(IKC=>'monitor', "\u$type${pid}Client"=>{
            register=>'inet_register',
            unregister=>'inet_unregister'
        });
        return;
    }
    my $exec="$Config{perlpath} -I./blib/arch -I./blib/lib -I$Config{archlib} -I$Config{privlib} test-client $type$$";
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
sub inet_register
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];

    $heap->{connected}++;
    $heap->{connections}++;
    ok( ($heap->{connected} <= 2), 
            "Max 2 concurrent connections ($heap->{connected})" );
        
    DEBUG and warn "Server: inet_register\n";
    # ::is($name, 'InetClient');
}

###########################################################
sub inet_unregister
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    $heap->{connected}--;
    DEBUG and warn "Server: inet_unregister ($name)\n";
    # ::is($name, 'InetClient');
    $kernel->delay('timeout');
    if( $heap->{connections} == 5 ) {
        $kernel->post( IKC=>"shutdown");
    }
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

