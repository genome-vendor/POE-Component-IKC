use ExtUtils::MakeMaker;

WriteMakefile(
    'NAME'	=> 'POE::Component::IKC',
    'VERSION_FROM' => 'IKC.pm', # finds $VERSION
    DISTNAME => 'POE-Component-IKC',
    dist=>{COMPRESS=>'gzip -9f', EXT=>'gz'},
    PREREQ_PM =>{
            POE          => 1,
            Scalar::Util => 1,
            Test::More   => 0.8
        },
    ABSTRACT => 'Inter-Kernel Communication for POE',
    LICENSE => 'perl'    
);
