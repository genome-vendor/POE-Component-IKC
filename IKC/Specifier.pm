package POE::Component::IKC::Specifier;

############################################################
# $Id$
#
# Copyright 1999 Philip Gwyn.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# Contributed portions of IKC may be copyright by their respective
# contributors.  

use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw( specifier_parse specifier_name );
$VERSION = '0.09';

sub DEBUG { 0 }

#----------------------------------------------------
# Turn an specifier into a hash ref
sub specifier_parse ($)
{
    my($specifier)=@_;
    return if not $specifier;
    unless(ref $specifier)
    {
        if($specifier=~m(^poe:
                        (?:
                            (//)
                            (\*|[-. \w]+|[a-zA-Z0-9][-.a-zA-Z0-9]+:\d+)?
                        )?
                        (?:
                            (/)
                            ([- \w]+)        
                        )?
                        (?: 
                            (/)?
                            ([- \w]*)
                        )?
                        $)x)
        {
            $specifier={kernel=>$2, session=>$4, state=>$6};
        } else
        {
            return;
        }
    } 
    $specifier->{kernel}||='';
    $specifier->{session}||='';
    $specifier->{state}||='';
    return $specifier;
}

#----------------------------------------------------
# Turn an specifier into a string
sub specifier_name ($)
{
    my($specifier)=@_;
    return $specifier unless(ref $specifier);
    if(ref($specifier) eq 'ARRAY')
    {
        $specifier={kernel=>'', 
                    session=>$specifier->[0], 
                    state=>$specifier->[1],
                   };
    }

    my $name='poe:';
    if($specifier->{kernel})
    {
        $name.='//';
        $name.=$specifier->{kernel};
    }
    if($specifier->{session})
    {
        $name.='/'.$specifier->{session};
        $name.='/' if $specifier->{state};
    }
    $name.=($specifier->{state}||'')    if $specifier->{state};
    return $name;
}


1;

__END__

=head1 NAME

POE::Component::IKC::Speicier - POE Inter-Kernel Communication specifer

=head1 SYNOPSIS

    use POE;
    use POE::Component::IKC::Specifier;
    $state=specifier_parse('poe://*/timeserver/connect');
    print 'The foreign state is '.specifier_name($state);

=head1 DESCRIPTION

This is a helper module that encapsulates POE IKC specifiers.  An IKC
specifier is a way of designating either a kernel, a session or a state
within a IKC cluster.  

IKC specifiers have the folloing format :

    poe:://kernel/session/state

B<kernel> may a kernel name, a kernel ID, blank (for local kernel), a
'*' (all known foreign kernels) or host:port (not currently supported).

B<session> may be any session alias that has been published by the foreign
kernel.

B<state> is a state that has been published by a foreign session.

Examples :

=over 4

=item C<poe://Pulse/timeserver/connect>

State 'connect' in session 'timeserver' on kernel 'Pulse'.

=item C<poe:/timeserver/connect>

State 'connect' in session 'timeserver' on the local kernel.

=item C<poe://*/timeserver/connect>

State 'connect' in session 'timeserver' on any known foreign kernel.
    
=item C<poe://Billy/bob/>

Session 'bob' on foreign kernel 'Billy'.

=back

=head1 EXPORTED FUNCTIONS

=item C<specifier_parse($spec)>

Turn a specifier into the internal representation (hash ref).  Returns
B<undef()> if the specifier wasn't valid.

    print Dumper specifer_parse('poe://Pulse/timeserver/time');

would print

    $VAR1 = {
        kernel => 'Pulse',
        session => 'timeserver',
        state => 'time',
    };

B<Note> : the internal representation might very well change some day.

=item C<specifier_name($spec)>

Turns a specifier into a string.


=head1 BUGS

=head1 AUTHOR

Philip Gwyn, <fil@pied.nu>

=head1 SEE ALSO

L<POE>, L<POE::Component::IKC::Responder>

=cut

