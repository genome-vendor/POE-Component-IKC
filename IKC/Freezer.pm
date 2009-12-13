package POE::Component::IKC::Freezer;

############################################################
# $Id: Freezer.pm,v 1.9 2005/08/04 22:01:30 fil Exp $
# Copyright 2001,2002,2004 Philip Gwyn.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

use strict;
use Data::Dumper;

use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);
use Carp;

require Exporter;
@ISA = qw(Exporter);
@EXPORT_OK = qw(freeze thaw dclone);
$VERSION = '0.18';

sub DEBUG { 0 }


############################################################
sub freeze
{
    my($data)=@_;
    local $Data::Dumper::Purity = 1;
    local $Data::Dumper::Indent = 0;
    local $Data::Dumper::Varname = __PACKAGE__."::VAR";
    return Dumper $data;
}

############################################################
sub thaw
{
    my($string)=@_;
    local $POE::Component::IKC::Freezer::VAR1;
    eval $string;
    return $POE::Component::IKC::Freezer::VAR1;
}

############################################################
sub dclone { thaw(freeze($_[0])); }


1;
__END__
# Below is the stub of documentation for your module. You better edit it!

=head1 NAME

POE::Component::IKC::Freezer - Pure-Perl serialization method.

=head1 SYNOPSIS

=head1 DESCRIPTION

This serializer uses C<Data::Dumper> and C<eval $code> to get the deed
done.  There is an obvious security problem here.  However, it has the
advantage of being pure Perl and all modules come with the core Perl
distribution.


=head1 BUGS

=head1 AUTHOR

Philip Gwyn, <perl-ikc at pied.nu>

=head1 SEE ALSO

L<POE>, L<POE::Component::IKC::Client>.

=cut

