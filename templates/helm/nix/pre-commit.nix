{ packages, formatter, pre-commit-lib }:
pre-commit-lib.run {
  src = ./.;

  hooks = {
    a-helm-lint = {
      enable = true;
      name = "Helm Lint";
      description = "Lint Helm charts for best practices";
      entry = "${packages.infrautils}/bin/helm lint infra/root_chart";
      files = "infra/root_chart/.*";
      language = ''system'';
      pass_filenames = false;
    };

    a-helm-docs = {
      enable = true;
      name = "Helm Docs";
      description = "Generate Helm chart documentation";
      entry = "${packages.infralint}/bin/helm-docs --chart-search-root infra/root_chart";
      files = "infra/root_chart/.*";
      language = ''system'';
      pass_filenames = false;
    };
  };
}
