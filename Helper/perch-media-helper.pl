#!/usr/bin/perl
# Loads PerchMediaHelper.dylib into the system Perl and runs it.
# Usage: /usr/bin/perl perch-media-helper.pl /absolute/path/PerchMediaHelper.dylib
use strict;
use warnings;
use DynaLoader;

my $path = shift @ARGV or die "missing library path\n";
my $lib = DynaLoader::dl_load_file($path, 0) or die "cannot load $path\n";
my $sym = DynaLoader::dl_find_symbol($lib, "perch_main") or die "entry point not found\n";
DynaLoader::dl_install_xsub("main::perch_main", $sym);
$| = 1;
perch_main();
