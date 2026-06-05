{ packages, formatter, pre-commit-lib }:
pre-commit-lib.run {
  src = ./.;

  hooks = {
    a-hadolint = {
      enable = true;
      name = "Hadolint";
      description = "Lint Dockerfiles for best practices";
      entry = "${packages.hadolint}/bin/hadolint";
      files = "Dockerfile$";
      language = ''system'';
      pass_filenames = true;
    };
  };
}
