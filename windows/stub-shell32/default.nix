{ stdenv, windows }:

stdenv.mkDerivation {
  pname = "stub-shell32";
  version = "0.1.0";

  src = ./.;

  buildInputs = [ windows.pthreads ];

  buildPhase = ''
    $CC -shared -o shell32.dll shell32.c shell32.def \
      -lole32 -lkernel32 \
      -Wl,--out-implib,libshell32.a
  '';

  installPhase = ''
    mkdir -p $out/bin $out/lib
    cp shell32.dll $out/bin/
    cp libshell32.a $out/lib/
  '';
}
