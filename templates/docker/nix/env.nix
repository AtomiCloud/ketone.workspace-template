{ pkgs, packages }:
with packages;
{
  system = [
    infrautils
  ];

  dev = [
    skopeo
  ];

  main = [
  ];

  lint = [
    infralint
  ];

  releaser = [
  ];
}
