#!/usr/bin/perl -w
use strict;
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..25\n"; }
use POE::Component::IKC::Server;
use POE::Component::IKC::Channel;
use POE::Component::IKC::Client;
use POE qw(Kernel);
my $loaded = 1;
END {print "not ok 1\n" unless $loaded;}
print "ok 1\n";

######################### End of black magic.

my $Q=2;
sub DEBUG () {0}


DEBUG and print "Starting servers...\n";
POE::Component::IKC::Server->spawn(
        unix=>($ENV{TMPDIR}||$ENV{TEMP}||'/tmp').'/IKC-test.pl',
        name=>'Unix',
    );

POE::Component::IKC::Server->spawn(
        port=>1338,
        name=>'Inet',
        aliases=>[qw(Ikc)],
    );

Test::Server->spawn();

$poe_kernel->run();

ok(25);

sub ok
{
    my($n, $ok)=@_;
    my $not=(not defined($ok) or $ok) ? '' : "not ";
    if(defined $n) {
        if($n < $Q) {
            $not="not ";
        } elsif($n > $Q) {
            foreach my $i ($Q .. ($n-1)) {
                print "not ok $i\n";
            }
            $Q=$n;
        }
    }
    print "${not}ok $Q\n";
    $Q++;
}

############################################################################
package Test::Server;
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
                        unix_register unix_unregister
                        inet_register inet_unregister
                        ikc_register ikc_unregister
                        done shutdown    do_child timeout
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
    ok(2);

    $kernel->alias_set('test');
    $kernel->call(IKC=>'publish',  test=>[qw(posted called method done)]);

    my $published=$kernel->call(IKC=>'published', 'test');
#    die Denter $published;
    ok(3, (ref $published eq 'ARRAY' and @$published==4));

    $published=$kernel->call(IKC=>'published');
    ok(4, (ref $published eq 'HASH' and 2==keys %$published));

    $kernel->post(IKC=>'monitor', 'UnixClient'=>{
            register=>'unix_register',
            unregister=>'unix_unregister'
        });
    $kernel->post(IKC=>'monitor', 'InetClient'=>{
            register=>'inet_register',
            unregister=>'inet_unregister'
        });
    $kernel->post(IKC=>'monitor', 'IkcClient'=>{
            register=>'ikc_register',
            unregister=>'ikc_unregister'
        });
    $kernel->post(IKC=>'monitor', '*'=>{shutdown=>'shutdown'});

    $kernel->yield(do_child=>'unix');
}

###########################################################
sub do_child
{
    my($kernel, $type)=@_[KERNEL, ARG0];
    my $pid=fork();
    die "Can't fork: $!\n" unless defined $pid;
    if($pid) {          # parent
        $kernel->delay(timeout=>60);
        return;
    }
    my $exec="$Config{perlpath} -I./blib/arch -I./blib/lib -I$Config{archlib} -I$Config{privlib} test-client $type";
    exec $exec;
    die "Couldn't exec $exec: $!\n";
}


###########################################################
sub _stop
{
    my($kernel, $heap)=@_[KERNEL, HEAP, ARG0];
    DEBUG and warn "Server: _stop\n";
    ok(24);
}

###########################################################
sub posted
{
    my($kernel, $heap, $type)=@_[KERNEL, HEAP, ARG0];
    DEBUG and warn "Server: posted\n";
    # 6, 12, 18
    ok($heap->{q}+1, ($type eq 'posted'));
}

###########################################################
sub called
{
    my($kernel, $heap, $type)=@_[KERNEL, HEAP, ARG0];
    DEBUG and warn "Server: called\n";
    # 7, 13, 19
    ok($heap->{q}+2, ($type eq 'called'));
}

###########################################################
sub method
{
    my($kernel, $heap, $sender, $type)=@_[KERNEL, HEAP, SENDER, ARG0];
    DEBUG and warn "Server: method\n";
    # 8, 14, 20
    ok($heap->{q}+3, ($type eq 'method'));
    $kernel->post($sender, 'YOW');
}




###########################################################
sub done
{
    my($kernel, $heap)=@_[KERNEL, HEAP];
    # 9, 15, 21
    DEBUG and warn "Server: done\n";
    ok($heap->{q}+4);
}






###########################################################
sub unix_register
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: unix_register\n";
    $heap->{q}=5;
    ok($heap->{q}, ($name eq 'UnixClient'));
}

###########################################################
sub unix_unregister
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: unix_unregister\n";
    ok(10, ($name eq 'UnixClient'));
    $kernel->yield(do_child=>'inet');
}

###########################################################
sub inet_register
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: inet_register\n";
    $heap->{q}=11;
    ok($heap->{q}, ($name eq 'InetClient'));
}

###########################################################
sub inet_unregister
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: inet_unregister ($name)\n";
    ok(16, ($name eq 'InetClient'));
    $kernel->delay('timeout');
    $kernel->yield(do_child=>"ikc");
}


###########################################################
sub ikc_register
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: ikc_register\n";
    $heap->{q}=17;
    ok($heap->{q}, ($name eq 'IkcClient'));
}

###########################################################
sub ikc_unregister
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: ikc_unregister ($name)\n";
    ok(22, ($name eq 'IkcClient'));
    $kernel->delay('timeout');
    $kernel->post(IKC=>'shutdown');
}


###########################################################
sub shutdown
{
    my($kernel, $heap, $name, $alias, $is_alias, 
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Server: shutdown\n";
    ok(23);
}

###########################################################
sub timeout
{
    my($kernel)=$_[KERNEL];
    warn "Server: Timedout waiting for child process.\n";
    $kernel->post(IKC=>'shutdown');
}
