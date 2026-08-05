{ pkgs, packages }:
with packages;
{
  system = [
    infrautils
  ];

  dev = [
  ];

  main = [
  ];

  lint = [
    infralint
  ];

  releaser = [
  ];
}
