use ExtUtils::MakeMaker;

print <<NOTICE;

---------------------------------------------------------------

It appears IKC causes POE version 0.29 and better to exercise a
bug in some versions of Perl that prevents wheel's DESTROY from
being called.  Until this issue has been resolved, IKC uses a 
work around that calls the wheel's DESTROY explicitly.  You may
find and deactivate this by commenting out the line after
WORK AROUND in IKC/Server.pm, IKC/Channel.pm and IKC/Client.pm

---------------------------------------------------------------

NOTICE

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

WriteMakefile(
    'NAME'	=> 'POE::Component::IKC',
    'VERSION_FROM' => 'IKC/Server.pm', # finds $VERSION
    DISTNAME => 'POE-Component-IKC',
    dist=>{COMPRESS=>'gzip -9f', EXT=>'gz'},
    PREREQ_PM =>{POE=>0.1701},
);
