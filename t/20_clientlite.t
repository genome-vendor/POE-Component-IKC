#!/usr/bin/perl -w

use strict;

use strict;
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..3\n"; }
use POE::Component::IKC::ClientLite;
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
print ($p ? '' : 'not ');
print "ok ", $Q++, "\n";

# try loading freezer
my($f, $t)=
    POE::Component::IKC::ClientLite::_get_freezer('POE::Component::IKC::Freezer');
print (($f and $t) ? '' : 'not ');
print "ok ", $Q++, "\n";

