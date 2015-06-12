package Module::FatPack;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(fatpack_modules);

our %SPEC;

my $mod_re    = qr/\A[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*\z/;
my $mod_pm_re = qr!\A[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*)*\.pm\z!;

$SPEC{fatpack_modules} = {
    v => 1.1,
    summary => 'Generate source code that contains fatpacked modules',
    description => <<'_',

This routine provides the same core technique employed by `App::Fatpack` (which
is putting modules' source code inside Perl variables and loading them on-demand
via require hook) without all the other stuffs. All you need is supply the names
of modules (or the modules' source code themselves) and you'll get the output in
a file or string.

_
    args_rels => {
        req_one => ['module_names', 'module_srcs'],
        'dep_any&' => [
            [stripper_maintain_linum => ['stripper']],
            [stripper_ws             => ['stripper']],
            [stripper_comment        => ['stripper']],
            [stripper_pod            => ['stripper']],
            [stripper_log            => ['stripper']],
        ],
    },
    args => {
        module_names => {
            summary => 'Module names to search',
            schema  => ['array*', of=>['str*', match=>$mod_re], min_len=>1],
            tags => ['category:input'],
            pos => 0,
            greedy => 1,
            'x.schema.element_entity' => 'modulename',
        },
        module_srcs => {
            summary => 'Module source codes',
            schema  => ['hash*', {
                each_key=>['str*', match=>$mod_re],
                each_value=>['str*'],
                min_len=>1,
            }],
            tags => ['category:input'],
        },
        output => {
            summary => 'Output filename',
            schema => 'str*',
            cmdline_aliases => {o=>{}},
            tags => ['category:output'],
            'x.schema.entity' => 'filename',
        },
        overwrite => {
            summary => 'Whether to overwrite output if previously exists',
            'summary.alt.bool.yes' => 'Overwrite output if previously exists',
            schema => [bool => default => 0],
            tags => ['category:output'],
        },

        assume_strict => {
            summary => 'Assume code runs under stricture',
            schema => 'bool',
            default => 1,
        },

        stripper => {
            summary => 'Whether to strip included modules using Perl::Stripper',
            'summary.alt.bool.yes' => 'Strip included modules using Perl::Stripper',
            schema => ['bool' => default=>0],
            tags => ['category:stripping'],
        },
        stripper_maintain_linum => {
            summary => "Set maintain_linum=1 in Perl::Stripper",
            schema => ['bool'],
            default => 0,
            tags => ['category:stripping'],
            description => <<'_',

Only relevant when stripping using Perl::Stripper.

_
        },
        stripper_ws => {
            summary => "Set strip_ws=1 (strip whitespace) in Perl::Stripper",
            'summary.alt.bool.not' => "Set strip_ws=0 (don't strip whitespace) in Perl::Stripper",
            schema => ['bool'],
            default => 1,
            tags => ['category:stripping'],
            description => <<'_',

Only relevant when stripping using Perl::Stripper.

_
        },
        stripper_comment => {
            summary => "Set strip_comment=1 (strip comments) in Perl::Stripper",
            'summary.alt.bool.not' => "Set strip_comment=0 (don't strip comments) in Perl::Stripper",
            schema => ['bool'],
            default => 1,
            description => <<'_',

Only relevant when stripping using Perl::Stripper.

_
            tags => ['category:stripping'],
        },
        stripper_pod => {
            summary => "Set strip_pod=1 (strip POD) in Perl::Stripper",
            'summary.alt.bool.not' => "Set strip_pod=0 (don't strip POD) in Perl::Stripper",
            schema => ['bool'],
            default => 1,
            tags => ['category:stripping'],
            description => <<'_',

Only relevant when stripping using Perl::Stripper.

_
        },
        stripper_log => {
            summary => "Set strip_log=1 (strip log statements) in Perl::Stripper",
            'summary.alt.bool.not' => "Set strip_log=0 (don't strip log statements) in Perl::Stripper",
            schema => ['bool'],
            default => 0,
            tags => ['category:stripping'],
            description => <<'_',

Only relevant when stripping using Perl::Stripper.

_
        },
        # XXX strip_log_levels

    },
};
sub fatpack_modules {
    my %args = @_;

    my %module_srcs; # key: mod_pm
    if ($args{module_srcs}) {
        for my $mod (keys %{ $args{module_srcs} }) {
            my $mod_pm = $mod; $mod_pm =~ s!::!/!g; $mod_pm .= ".pm";
            $module_srcs{$mod_pm} = $args{module_srcs}{$mod};
        }
    } else {
        require Module::Path::More;
        for my $mod (@{ $args{module_names} }) {
            my $mod_pm = $mod; $mod_pm =~ s!::!/!g; $mod_pm .= ".pm";
            next if $module_srcs{$mod_pm};
            my $path = Module::Path::More::module_path(
                module => $mod, find_pmc=>0);
            die "Can't find module '$mod_pm'" unless $path;
            $module_srcs{$mod_pm} = do {
                local $/;
                open my($fh), "<", $path or die "Can't open $path: $!";
                ~~<$fh>;
            };
        }
    }

    if ($args{stripper}) {
        require Perl::Stripper;
        my $stripper = Perl::Stripper->new(
            maintain_linum => $args{stripper_maintain_linum} // 0,
            strip_ws       => $args{stripper_ws} // 1,
            strip_comment  => $args{stripper_comment} // 1,
            strip_pod      => $args{stripper_pod} // 1,
            strip_log      => $args{stripper_log} // 0,
        );
        for my $mod_pm (keys %module_srcs) {
            $module_srcs{$mod_pm} = $stripper->strip($module_srcs{$mod_pm});
        }
    }

    my @res;

    push @res, 'BEGIN {', "\n";
    push @res, 'my %fatpacked;', "\n\n";
    for my $mod_pm (sort keys %module_srcs) {
        my $label = uc($mod_pm); $label =~ s/\W+/_/g; $label =~ s/\_PM$//;
        push @res, '$fatpacked{"', $mod_pm, q|"} = '#line '.(1+__LINE__).' "'.__FILE__."\"\n".<<'|, $label, "';\n";
        $module_srcs{$mod_pm} =~ s/^/  /gm;
        push @res, $module_srcs{$mod_pm};
        push @res, "$label\n\n";
    }
    push @res, <<'_';
s/^  //mg for values %fatpacked;

my $class = 'FatPacked::'.(0+\%fatpacked);
_

    push @res, <<'_' if $args{assume_strict} // 1;
no strict 'refs';
_
    push @res, <<'_';
*{"${class}::files"} = sub { keys %{$_[0]} };

if ($] < 5.008) {
  *{"${class}::INC"} = sub {
     if (my $fat = $_[0]{$_[1]}) {
       return sub {
         return 0 unless length $fat;
         $fat =~ s/^([^\n]*\n?)//;
         $_ = $1;
         return 1;
       };
     }
     return;
  };
}

else {
  *{"${class}::INC"} = sub {
    if (my $fat = $_[0]{$_[1]}) {
      open my $fh, '<', \$fat
        or die "FatPacker error loading $_[1] (could be a perl installation issue?)";
      return $fh;
    }
    return;
  };
}

unshift @INC, bless \%fatpacked, $class;
  } # END OF FATPACK CODE
_

    if ($args{output}) {
        my $outfile = $args{output};
        if (-f $outfile) {
            return [409, "Won't overwrite existing file '$outfile'"]
                unless $args{overwrite};
        }
        open my($fh), ">", $outfile or die "Can't write to '$outfile': $!";
        print $fh join("", @res);
        return [200, "OK, written to '$outfile'"];
    } else {
        return [200, "OK", join("", @res)];
    }
}

1;
# ABSTRACT:

=head1 SEE ALSO

L<App::FatPack>, L<App::fatten>
