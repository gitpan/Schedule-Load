# $Id: Makefile.PL,v 1.4 2000/01/21 13:53:34 wsnyder Exp $

require 5.005;
use ExtUtils::MakeMaker;
use Carp;

sub MY::postamble {
"
install::
	-mkdir -p /usr/local/lib/rschedule
	-chmod a+rw /usr/local/lib/rschedule

README: readme.texi
	-rm \$@
	makeinfo \$< --output \$@ --no-headers --no-validate

maintainer-clean: distclean
	-rm README Makefile

dist: distcheck
";
}

## Remember to upgrade version number!
WriteMakefile(
	      DISTNAME	=> 'Schedule-Load',
	      NAME	=> 'Schedule::Load',
	      AUTHOR	=> 'Wilson Snyder <wsnyder@world.std.com>',
	      ABSTRACT_FROM => 'Load.pm',
	      VERSION_FROM  => 'Load.pm',
	      PREREQ_PM => {'Proc::ProcessTable' => 0,
			    'Unix::Processors' => 0,},  #1.6, but no VERSION there
	      EXE_FILES	=> [qw( rschedule slchoosed slreportd slpolice)],
	      'clean'	=> {FILES => 'test_store', },
	      'dist'	=> {COMPRESS => 'gzip -9f',
			    SUFFIX   => '.gz', 
			    DIST_DEFAULT => 'README all tardist',
			},
	      );

