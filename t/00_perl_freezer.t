#!/usr/bin/perl -w
use strict;

BEGIN { $| = 1; print "1..8\n"; }
use POE::Component::IKC::Freezer qw(freeze thaw dclone);
my $loaded = 1;
END {print "not ok 1\n" unless $loaded;}
print "ok 1\n";

######################### End of black magic.

my $q=1;

my $data={foo=>"bar", biff=>[qw(hello world)]};


my $str=freeze($data);
print $str ? '' : 'not ';
print "ok ", ++$q, "\n";

my $data2=thaw($str);
print $str ? '' : 'not ';
print "ok ", ++$q, "\n";
deep_compare($data, $data2, ++$q);


$data2=dclone($data);
deep_compare($data, $data2, ++$q);


$data->{biffle}=$data->{biff};
$data2=dclone($data);
print $data->{biffle}==$data->{biff} ? '' : 'not ';
print "ok ", ++$q, "\n";
deep_compare($data, $data2, ++$q);


# circular reference
$data->{flap}=$data->{biffle};
push @{$data->{biffle}}, $data->{flap};
$data2=dclone($data);

print $data->{biffle}[-1]==$data->{biffle} ? '' : 'not ';
print "ok ", ++$q, "\n";


##################################################################
sub deep_compare
{
    my($one, $two, $n)=@_;
    print _deep_compare($one, $two) ? '' : 'not ';
    print "ok $n\n";
}

sub _deep_compare
{
    my($one, $two)=@_;
    my $r1=ref($one);
    my $r2=ref($two);
    unless($r1 and $r2) {
        return 1 unless defined($one) or defined($two);
        return $one eq $two;
    }
    return unless $r1 eq $r2;    

    if($r1 eq 'HASH') {
        return unless _deep_compare([sort keys %$one], [sort keys %$two]);
        foreach my $k (%$one) {
            return unless _deep_compare($one->{$k}, $two->{$k});
        }
        return 1;
    }

    if($r1 eq 'ARRAY') {
        return unless @$one == @$two;
        for(my $q=0; $q<=$#$one; $q++) {
            return unless _deep_compare($one->[$q], $two->[$q]);
        }
        return 1;
    }
    if($r1 eq 'SCALAR') {
        return __deep_compare($$one, $$two);
    }
    die "Shouldn't be $r1!\n";
}