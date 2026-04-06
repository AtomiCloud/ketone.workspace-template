import { StartTemplateWithLambda, GlobType } from '@atomicloud/cyan-sdk';

StartTemplateWithLambda(async (i, d) => {
  const name = await i.text('Project name', 'cyan/new/name');
  const description = await i.text('Project description', 'cyan/new/description');
  const open = '{' + '{';
  const close = '}' + '}';

  return {
    processors: [
      {
        name: 'cyan/default',
        files: [
          {
            root: 'templates',
            glob: '**/*',
            type: GlobType.Template,
            exclude: [],
          },
        ],
        config: {
          vars: { projectName: name, projectDescription: description },
          parser: {
            varSyntax: [
              [open, close],
              ['// ' + open, close],
              ['# ' + open, close],
            ],
          },
        },
      },
    ],
    plugins: [],
  };
});
