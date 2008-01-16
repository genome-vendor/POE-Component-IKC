use ExtUtils::MakeMaker;

my $warn_poe;
eval "use POE;";
if( $@ or ( $POE::VERSION > 0.29 and $POE::VERSION < 0.37 ) ) {
    $warn_poe = 1;
}

if( $warn_poe ) {

    my $current = '';
    if( $POE::VERSION ) {
        $current = "You currently have POE $POE::VERSION installed.\n";
    }


    print <<NOTICE;

---------------------------------------------------------------
$current
It appears IKC causes POE version 0.29 - 0.36 to exercise a bug in some
versions of Perl that prevents wheel's DESTROY from being called.  This
issue has been resolved in 0.37.  If you can not upgrade your version of
POE, IKC has a work around that calls the wheel's DESTROY explicitly.  You
may find and reactivate this by uncommenting lines after WORK AROUND in
IKC/Server.pm, IKC/Channel.pm and IKC/Client.pm

---------------------------------------------------------------

NOTICE

}

WriteMakefile(
    'NAME'	=> 'POE::Component::IKC',
    'VERSION_FROM' => 'IKC.pm', # finds $VERSION
    DISTNAME => 'POE-Component-IKC',
    dist=>{COMPRESS=>'gzip -9f', EXT=>'gz'},
    PREREQ_PM =>{
            POE          => 0.32,
            Scalar::Util => 1,
        },
    ABSTRACT => 'Inter-Kernel Communication for POE',
    LICENSE => 'perl'    
);
