#!/usr/bin/perl -w

use strict;

# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

# sub POE::Kernel::ASSERT_EVENTS { 1 }
# sub POE::Kernel::TRACE_REFCNT { 1 }

BEGIN { $| = 1; print "1..11\n"; }
use POE::Component::IKC::ClientLite;
use POE::Component::IKC::Server;
use POE::Component::IKC::Responder;
use Data::Dumper;

use POE qw(Kernel);
my $loaded = 1;
END {print "not ok 1\n" unless $loaded;}
print "ok 1\n";

######################### End of black magic.

my $Q=2;
sub DEBUG () {0}

# try finding a freezer
my $p=
    POE::Component::IKC::ClientLite::_default_freezer();
ok(2, !!$p);

# try loading freezer
my($f, $t)=
    POE::Component::IKC::ClientLite::_get_freezer('POE::Component::IKC::Freezer');
ok(3, ($f and $t));

POE::Component::IKC::Responder->spawn;

POE::Component::IKC::Server->spawn(
        port=>1337,
        name=>'Inet',
        aliases=>[qw(Ikc)],
    );

DEBUG and print "Test server $$\n";
Test::Server->spawn();

$poe_kernel->run();

ok(11);



#############################################
sub ok
{
    my($n, $ok, $reason)=@_;
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
    my $skip='';
    $skip=" # skipped: $reason" if $reason;
    print "${not}ok $Q$skip\n";
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
            $package=>[qw(_start _stop fetchQ add_1 add_n here
                        lite_register lite_unregister
                        shutdown do_child timeout
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
    DEBUG and warn "Test server: _start\n";
    ok(4);

    $kernel->alias_set('test');
    $kernel->call(IKC=>'publish',  test=>[qw(fetchQ add_1 here)]);

    $kernel->post(IKC=>'monitor', 'LiteClient'=>{
            register=>'lite_register',
            unregister=>'lite_unregister'
        });
    $kernel->post(IKC=>'monitor', '*'=>{shutdown=>'shutdown'});

    $kernel->delay(do_child=>1, 'lite');
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
    my $exec="$Config{perlpath} -I./blib/arch -I./blib/lib -I$Config{archlib} -I$Config{privlib} test-$type";
    exec $exec;
    die "Couldn't exec $exec: $!\n";
}


###########################################################
sub _stop
{
    my($kernel, $heap)=@_[KERNEL, HEAP, ARG0];
    DEBUG and warn "Test server: _stop\n";
    ok(10);
}


###########################################################
my $count=0;
sub lite_register
{
    my($kernel, $heap, $name, $alias, $is_alias,
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Test server: lite_register\n";
    return if $count++;
    ok(5, ($name eq 'LiteClient'));
}

###########################################################
sub lite_unregister
{
    my($kernel, $heap, $name, $alias, $is_alias,
                            )=@_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    DEBUG and warn "Test server: lite_unregister count=$count\n";
    return if $count==1;

    ok(9, ($name eq 'LiteClient'));
    $kernel->delay('timeout');          # set in do_child
    $kernel->post(IKC=>'shutdown');
}

###########################################################
sub shutdown
{
    my($kernel)=$_[KERNEL];
    $kernel->alias_remove('test');
    DEBUG and warn "Test server: shutdown\n";
#    use YAML qw(Dump);
#    use Data::Dumper;
#    warn Dumper $kernel;
}
###########################################################
sub fetchQ
{
    my($kernel, $heap)=@_[KERNEL, HEAP];
    return ok(6)+1;
}

###########################################################
sub add_1
{
    my($kernel, $heap, $args)=@_[KERNEL, HEAP, ARG0];
    DEBUG and warn "$$: add_1";
    my($n, $pb)=@$args;
    DEBUG and warn "$$: foo $n";
    ok($n);     # 7
    $kernel->yield('add_n', $n, 1, $pb);
}

###########################################################
sub add_n
{
    my($kernel, $n, $q, $pb)=@_[KERNEL, ARG0, ARG1, ARG2];
    DEBUG and warn "$$: add_n $n+$q";
    $kernel->post(IKC=>'post', $pb=>$n+$q);
}

###########################################################
sub here
{
    my($kernel, $n)=@_[KERNEL, ARG0];
    DEBUG and warn "$$: here $n";
    ok($n);     # 8
}

###########################################################
sub timeout
{
    my($kernel)=$_[KERNEL];
    warn "Test server: Timedout waiting for child process.\n";
    $kernel->post(IKC=>'shutdown');
}




