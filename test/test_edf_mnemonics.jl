# Expected values were checked against silx's `fabioh5.File` reading the same header:
# positioners samy/samz/phi/extra, counters mon/det, and the NXsample unit cell and UB matrix.

@testset "EDF SPEC mnemonics" begin
    h = Header()
    h["motor_mne"] = "samy samz  phi extra"      # one name more than values
    h["motor_pos"] = "1.5 -0.25 90"
    h["counter_mne"] = "mon det"                 # one value more than names
    h["counter_pos"] = "1000 2500 77"
    h["UB_mne"] = join(("UB$i" for i = 0:8), " ")
    h["UB_pos"] = "1.1 0.2 0.3 0.4 1.5 0.6 0.7 0.8 1.9"
    h["sample_mne"] = "U0 U1 U2 U3 U4 U5"
    h["sample_pos"] = "5.43 5.43 5.43 90 90 120"

    # Through a real file, so the header is what the EDF reader hands back.
    path = joinpath(TMP, "mnemonics.edf")
    writeimage(path, reshape(Float32.(1:12), 4, 3); header = h)
    hdr = header(readimage(path))

    m = Fabio.edfmnemonics(hdr, "motor")
    @test collect(keys(m)) == ["samy", "samz", "phi", "extra"]
    @test m["samy"] == "1.5" && m["samz"] == "-0.25" && m["phi"] == "90"
    @test m["extra"] === nothing
    c = Fabio.edfmnemonics(hdr, "counter")
    @test collect(pairs(c)) == ["mon" => "1000", "det" => "2500"]
    @test isempty(Fabio.edfmnemonics(hdr, "nosuch"))
    @test isempty(Fabio.edfmnemonics(hdr, "Motor"))           # case-sensitive, as in FabIO

    @test Fabio.hasedfsample(hdr)
    s = Fabio.edfsample(hdr)
    @test s.unit_cell_abc == [5.43, 5.43, 5.43]
    @test s.unit_cell_alphabetagamma == [90.0, 90.0, 120.0]
    @test s.ub_matrix == [1.1 0.2 0.3; 0.4 1.5 0.6; 0.7 0.8 1.9]   # UB0 UB1 UB2 is row 1

    @test Fabio.edfsample(Header()) === nothing
    @test !Fabio.hasedfsample(Header())
    bad = copy(h)
    bad["UB_pos"] = "1 2 3"
    err = try
        Fabio.edfsample(bad)
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("UB mnemonic UB3", sprint(showerror, err))
end
