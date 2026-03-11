derivation {
  name = "hello";
  system = "x86_64-windows";
  builder = "cmd.exe";
  args = [ "/c" "echo Hello > %out%" ];
}
