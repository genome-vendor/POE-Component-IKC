use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'	=> 'POE::Component::IKC',
    'VERSION_FROM' => 'IKC/Server.pm', # finds $VERSION
    DISTNAME => 'POE-Component-IKC',
    dist=>{COMPRESS=>'gzip -9f', EXT=>'gz'},
    PREREQ_PM =>{POE=>0.1403},
);
