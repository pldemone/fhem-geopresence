package main;

use strict;
use warnings;

our %keys;

# Model the FHEM API's regex deletion semantics, including dots in device
# names. The actual file boundary is also exercised by integration tests.
sub setKeyValue {
    my ($pattern,$value)=@_;
    delete @keys{grep {/\A$pattern\z/} keys %keys};
    $keys{$pattern}=$value if defined $value;
    return;
}

sub FileRead { return (undef,map {$_ . ':' . $keys{$_}} sort keys %keys); }

sub FileWrite {
    my ($path,@lines)=@_;
    %keys=();
    for my $line (@lines) {
        my ($key,$value)=split /:/,$line,2;
        $keys{$key}=$value if defined $value;
    }
    return;
}

1;
