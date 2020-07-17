package Test2::Plugin::VerifyModuleLoaded;
use strict;
use warnings;

use v5.10;

our $VERSION = '0.000001';

use XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

use Test2::API qw/test2_add_callback_exit context/;
use Path::Tiny qw/path/;
use Carp qw/croak/;
use File::Spec();
use B;

my $SEP = File::Spec->catfile('', '');

our (%FILES, %LOADS);

my $IMPORTED = 0;
sub import {
    my $class = shift;
    my %params = @_;

    if ($IMPORTED++) {
        croak "$class has already been imported, too late to add params" if keys %params;
        return;
    }

    my $ran = 0;
    $params{root} //= path('.')->realpath;

    test2_add_callback_exit(sub { $class->callback(%params) });
}

sub clean_tree {
    my $class = shift;
    my ($tree, %params) = @_;

    my %seen;
    my @keys = keys %$tree;
    for my $key_file (@keys) {
        next if $seen{$key_file};

        my $key_ex = $class->extract($key_file, %params);

        if (!$key_ex) {
            delete $tree->{$key_file} if $params{subsumes};
            next;
        }

        my $key_norm = $class->normalize($key_ex, %params);

        if ($params{subsumes} && !$class->subsumes($key_norm, %params)) {
            delete $tree->{$key_file};
            delete $tree->{$key_norm};
            next;
        }

        if ($key_norm) {
            my $new;
            if (ref($tree->{$key_file}) eq 'HASH') {
                my $old = delete $tree->{$key_file};
                my $mix = delete $tree->{$key_norm} // {};
                $new = {%$old, %$mix};

                $class->clean_tree($new, %params, subsumes => $params{subsumes} ? $params{subsumes} - 1 : 0);
            }
            else {
                delete $tree->{$key_file};
                $new = 1;
            }

            $tree->{$key_norm} = $new;
            $seen{$key_norm} = 1;
        }
    }
}

sub display_path {
    my $class = shift;
    my ($in, %params) = @_;

    my $rel = path($in)->relative($params{root})->stringify();

    return $in if $rel =~ m/\.\./;
    return $rel;
}

sub callback {
    my $class = shift;
    my %params = @_;

    my $root = $params{root} //= path('.')->realpath;

    # Ignore further modifications
    my $loads = {%LOADS};
    my $files = {%FILES};
    %LOADS = ();
    %FILES = ();

    $class->clean_tree($loads, %params, subsumes => 0);
    $class->clean_tree($files, %params, subsumes => 1);

    my %bad;
    for my $consumer (keys %$files) {
        my $consumed = $files->{$consumer};
        my $loaded   = $loads->{$consumer} // {};
        my $imports;

        for my $check (keys %$consumed) {
            next if $check eq $consumer;
            next if $check =~ m/eval/;
            next if $loaded->{$check};

            $imports //= $class->find_imports($consumer);
            next if $imports->{$check};

            push @{$bad{$consumer}} => $check;
        }
    }

    return unless keys %bad;

    my $message = "The following files executed code from files without loading them first:\n";
    while (my ($consumer, $list) = each %bad) {
        $message .= "\n" . $class->display_path($consumer, %params) . "\n" . join "\n" => map { "    " . $class->display_path($_, %params) } sort @$list;
        $message .= "\n\n";
    }

    if ($params{fatal}) {
        die $message;
    }
    else {
        warn $message;
    }
}

sub find_imports {
    my $class = shift;
    my ($file) = @_;

    state $cni = $class->CNI;

    my $pkgs = $cni->{$file} or return {};

    my $out = {};
    for my $pkg (@$pkgs) {
        my $stash = do { no strict 'refs'; \%{"$pkg\::"} };
        for my $sym (keys %$stash) {
            my $sub = $pkg->can($sym) or next;
            $out->{B::svref_2object($sub)->FILE}++;
        }
    }

    return $out;
}

sub CNI {
    my $class = shift;

    my $out = {};

    my $zero = $class->normalize($0);
    $out->{$zero->realpath} = ['main'] if $zero->exists;

    for my $key (keys %INC) {
        my $file = $class->normalize($key);

        my $package = $key;
        $package =~ s/\.(pmc?|xs)$//;
        $package =~ s/\Q$SEP\E/::/g;

        push @{$out->{$file}} => $package;
    }

    return $out;
}

sub subsumes {
    my $class = shift;
    my ($file, %params) = @_;

    my $root = $params{root};

    return unless $root->subsumes($file);

    return $file;
}

sub normalize {
    my $class = shift;
    my ($file) = @_;

    my $path = $INC{$file} ? path($INC{$file}) : path($file);
    $path = $path->realpath if $path->exists;

    return $path;
}

sub extract {
    my $class = shift;
    my ($file) = @_;

    # If we opened a file with 2-arg open
    $file =~ s/^[\+\-]?(?:>{1,2}|<|\|)[\+\-]?//;

    # Sometimes things get nested and we need to extract and then extract again...
    while (1) {
        # No hope :-(
        return if $file =~ m/^\(eval( \d+\)?)$/;

        # Easy
        return $file if -e $file;

        my $start = $file;

        # Moose like to write "blah blah (defined at filename line 123)"
        $file = $1 if $file =~ m/(?:defined|declared) (?:at|in) (.+) at line \d+/;
        $file = $1 if $file =~ m/(?:defined|declared) (?:at|in) (.+) line \d+/;
        $file = $1 if $file =~ m/\(eval \d+\)\[(.+):\d+\]/;
        $file = $1 if $file =~ m/\((.+)\) line \d+/;
        $file = $1 if $file =~ m/\((.+)\) at line \d+/;

        # Extracted everything away
        return unless $file;

        # Not going to change anymore
        last if $file eq $start;
    }

    # These characters are rare in file names, but common in calls where files
    # could not be determined, so we probably failed to extract. If this
    # assumption is wrong for someone they can write a custom extract, this is
    # not a bug.
    return if $file =~ m/([\[\]\(\)]|->|\beval\b)/;

    # If we have a foo.bar pattern, or a string that contains this platforms
    # file separator we will condifer it a valid file.
    return $file if $file =~ m/\S+\.\S+$/i || $file =~ m/\Q$SEP\E/;

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Plugin::VerifyModuleLoaded - fixme

=head1 DESCRIPTION

=head1 SOURCE

The source code repository for Test2-Plugin-VerifyModuleLoaded can be found at
F<https://github.com/Test-More/Test2-Plugin-VerifyModuleLoaded>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist@cpan.orgE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut

