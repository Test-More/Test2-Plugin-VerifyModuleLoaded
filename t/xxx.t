#!/usr/bin/perl
use Test2::V0;

use Test2::Plugin::VerifyModuleLoaded fatal => 0;

#use Data::Dumper;
{
    package XXX;
#    use Data::Dumper;
#    require Data::Dumper;
#    Data::Dumper->import();
}

Data::Dumper::Dumper('xxx');

ok(1);

done_testing();
