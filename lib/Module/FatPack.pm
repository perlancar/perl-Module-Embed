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
            cmdline_aliases => {m=>{}},
        },
        module_srcs => {
            summary => 'Module source codes (a hash, keys are module names)',
            schema  => ['hash*', {
                each_key=>['str*', match=>$mod_re],
                each_value=>['str*'],
                min_len=>1,
            }],
            tags => ['category:input'],
        },
        preamble => {
            summary => 'Perl source code to add before the fatpack code',
            schema => 'str*',
            tags => ['category:input'],
        },
        postamble => {
            summary => 'Perl source code to add after the fatpack code',
            schema => 'str*',
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

    },
    examples => [
        {
            summary => 'Fatpack two modules',
            src => 'fatpack-modules Text::Table::Tiny Try::Tiny',
            src_plang => 'bash',
            test => 0,
            'x.doc.show_result' => 0,
        },
    ],
};
sub fatpack_modules {
    my %args = @_;

    my %module_srcs; # key: mod_pm
    if ($args{module_srcs}) {
        for my $mod (keys %{ $args{module_srcs} }) {
            my $mod_pm = $mod; $mod_pm =~ s!::!/!g; $mod_pm .= ".pm" unless $mod_pm =~ /\.pm\z/;
            $module_srcs{$mod_pm} = $args{module_srcs}{$mod};
        }
    } else {
        require Module::Path::More;
        for my $mod (@{ $args{module_names} }) {
            my $mod_pm = $mod; $mod_pm =~ s!::!/!g; $mod_pm .= ".pm" unless $mod_pm =~ /\.pm\z/;
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

    push @res, $args{preamble} if defined $args{preamble};
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
    push @res, $args{postamble} if defined $args{postamble};

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

require PERLANCAR::AppUtil::PerlStripper; PERLANCAR::AppUtil::PerlStripper::_add_stripper_args_to_meta($SPEC{fatpack_modules});

1;
# ABSTRACT:

=head1 SEE ALSO

L<App::FatPack>, the original implementation.

L<App::depak> for more options e.g. strip the source codes first, use various tracing methods, etc.

L<fatpack-modules>, CLI for C<fatpack_modules>
