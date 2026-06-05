import { StartTemplateWithLambda, GlobType } from '@atomicloud/cyan-sdk';
import { standardPrompts } from './src/standard';

type CyanProcessor = {
  name: string;
  files: { root: string; glob: string; type: GlobType; exclude: string[] }[];
  config: unknown;
};

const llmExclude = ['**/CLAUDE.md', '**/.claude/**/*', '**/.claude/**/*.*'];

const varSyntax: [string, string][] = [
  ['let__', '__'],
  ['// let__', '__'],
  ['# let__', '__'],
];

StartTemplateWithLambda(async i => {
  const { platform, service, llm, docker, helm, secret } = await standardPrompts(i);

  const exclude = llm ? [] : llmExclude;
  const config = {
    vars: { platform, service },
    parser: { varSyntax },
  };

  const makeProcessor = (root: string): CyanProcessor => ({
    name: 'cyan/default',
    files: [
      {
        root,
        glob: '**/*',
        type: GlobType.Template,
        exclude,
      },
    ],
    config,
  });

  const processors: CyanProcessor[] = [makeProcessor('templates/base')];
  if (docker) processors.push(makeProcessor('templates/docker'));
  if (helm) processors.push(makeProcessor('templates/helm'));
  if (secret) processors.push(makeProcessor('templates/secret'));

  return {
    processors,
    plugins: [],
  };
});
