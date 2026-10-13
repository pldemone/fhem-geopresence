use strict;
use warnings;
use Test::More;
use FindBin;

# Only configuration validation is exercised here; no listener or actor starts.
our (%defs, %attr, %data, $init_done, $readingFnAttributes);
$readingFnAttributes = '';
sub setReadingsVal { $_[0]{READINGS}{$_[1]}={VAL=>$_[2],TIME=>$_[3]}; }
sub InternalTimer { }
sub RemoveInternalTimer { }
sub Log3 { }
sub getKeyValue { return (undef, ('a' x 32) . ':' . ('b' x 64)); }
require "$FindBin::Bin/../FHEM/98_GeoPresence.pm";

sub define_geo {
    my ($name, $definition) = @_;
    my $d = $defs{$name} = {NAME => $name, TYPE => 'GeoPresence'};
    my $error = GeoPresence_Define($d, "$name GeoPresence $definition");
    die $error if defined $error;
    return $d;
}

sub fixture {
    %defs = (); %attr = (); %data = (); $init_done = 0;
    my $c = define_geo('GP', 'controller');
    $attr{GP} = {webhookPort => 8090}; GP_StoreMode($defs{GP},'debug');
    $defs{rr_Test} = {NAME => 'rr_Test', TYPE => 'ROOMMATE'};
    $attr{rr_Test}{rr_locationUnderway} = 'underway';
    $defs{$_} = {NAME => $_, TYPE => 'PRESENCE'} for qw(p1 p2);
    define_geo('Geo.Test', 'resident GP rr_Test');
    $attr{'Geo.Test'} = {sourceMode => 'geofency_phone', deviceId => 'test-phone', webhookUser => 'test-user', phoneProxies => 'p1,p2'}; GP_StoreMode($defs{'Geo.Test'},'active');
    for my $role (qw(home outer)) {
        define_geo("Z.$role", "location Geo.Test $role");
        $attr{"Z.$role"}{zoneId} = "zone-$role";
    }
    $init_done = 1;
    return $c;
}

subtest 'removed parameters are absent from all registration paths' => sub {
    my $c = fixture();
    my $module = {};
    GeoPresence_Initialize($module);
    for my $initialized (0, 1) {
        local $init_done = $initialized;
        GP_UpdateAttrLists();
        for my $spec ($module->{AttrList}, $c->{'.AttrList'}, $defs{'Geo.Test'}{'.AttrList'}) {
            unlike($spec, qr/\b(?:phoneAggregate|absenceProxies|webDevice)\b/,
                "no retired attributes during " . ($initialized ? 'normal operation' : 'configuration loading'));
        }
    }
};

subtest 'both existing source modes validate without an aggregation device' => sub {
    my $c = fixture();
    for my $mode (qw(geofency_phone phone_only)) {
        $attr{'Geo.Test'}{sourceMode} = $mode;
        is_deeply([GP_Validate($c)], [], "$mode accepts individual PRESENCE sources alone");
        local $defs{GP}{READINGS}{mode}{VAL} = 'active';
        is_deeply([GP_Validate($c, undef, 1)], [], "$mode can activate without a dummy aggregate");
        is_deeply(GP_Config($c, 'Geo.Test')->{proxies}, [qw(p1 p2)], 'all configured room sensors remain sources');
    }
};

subtest 'cleanup does not relax requirements on the actual phone sources' => sub {
    my $c = fixture();
    for my $mode (qw(geofency_phone phone_only)) {
        $attr{'Geo.Test'}{sourceMode} = $mode;
        for my $list ('', 'p1,p1') {
            local $attr{'Geo.Test'}{phoneProxies} = $list;
            like(join('\n', GP_Validate($c)), qr/phoneProxies must list the house sensors without duplicates/,
                "$mode rejects missing or duplicate sources");
        }
        local $defs{p2}{TYPE} = 'dummy';
        like(join('\n', GP_Validate($c)), qr/invalid PRESENCE proxy p2/,
            "$mode still requires a real PRESENCE device for each source");
    }
};

done_testing;
