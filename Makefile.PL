# $Id: Makefile.PL,v 1.3 1999/12/11 14:37:49 wsnyder Exp $

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
	DISTNAME  => 'Schedule-Load',
	NAME      => 'Schedule::Load',
	VERSION_FROM => 'Load.pm',
	EXE_FILES => [qw( rschedule slchoosed slreportd slpolice)],
	'dist'    => {COMPRESS => 'gzip -9f',
		      SUFFIX   => '.gz', 
		      DIST_DEFAULT => 'README all tardist',
		     },
	);

