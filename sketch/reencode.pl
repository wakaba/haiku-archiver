use strict;
use warnings;

binmode STDIN, qw(:encoding(utf-8));
binmode STDOUT, qw(:encoding(utf-8));

## ^<https://chars.suikawiki.org/set?expr=-+%24unicode%3ANoncharacter_Code_Point+-+%24unicode%3AZ+-+%24unicode%3AWhite_Space+-+%24unicode%3Asurrogate+-+%24unicode%3ADefault_Ignorable_Code_Point+-+%24unicode%3AControl+-+%5B%5Cu005C%5D> | \x5C
while (<STDIN>) {
  if (/^(\S+) (.+)$/) {
    my $name = $1;
    my $value = $2;
    $value =~ s/([^!-\x5B\x5C\x5D-~\xA1-\xAC\xAE-\x{034E}\x{0350}-\x{061B}\x{061D}-\x{115E}\x{1161}-\x{167F}\x{1681}-\x{17B3}\x{17B6}-\x{180A}\x{180F}-\x{1FFF}\x{2010}-\x{2027}\x{2030}-\x{205E}\x{2070}-\x{2FFF}\x{3001}-\x{3163}\x{3165}-\x{D7FF}\x{E000}-\x{FDCF}\x{FDF0}-\x{FDFF}\x{FE10}-\x{FEFE}\x{FF00}-\x{FF9F}\x{FFA1}-\x{FFEF}\x{FFF9}-\x{FFFD}\x{10000}-\x{1BC9F}\x{1BCA4}-\x{1D172}\x{1D17B}-\x{1FFFD}\x{20000}-\x{2FFFD}\x{30000}-\x{3FFFD}\x{40000}-\x{4FFFD}\x{50000}-\x{5FFFD}\x{60000}-\x{6FFFD}\x{70000}-\x{7FFFD}\x{80000}-\x{8FFFD}\x{90000}-\x{9FFFD}\x{A0000}-\x{AFFFD}\x{B0000}-\x{BFFFD}\x{C0000}-\x{CFFFD}\x{D0000}-\x{DFFFD}\x{E1000}-\x{EFFFD}\x{F0000}-\x{FFFFD}\x{100000}-\x{10FFFD}])/sprintf "\\x{%04X}", ord $1/ge;
    print "$name $value\n";
  } else {
    print;
  }
}
