import type { IInquirer } from '@atomicloud/cyan-sdk';

export async function standardPrompts(i: IInquirer): Promise<{
  platform: string;
  service: string;
  llm: boolean;
  docker: boolean;
  helm: boolean;
  secret: boolean;
}> {
  const platform = (
    await i.text('Platform', 'atomi/platform', 'LPSM Service Tree Platform')
  ).toLowerCase();
  const service = (
    await i.text('Service', 'atomi/service', 'LPSM Service Tree Service')
  ).toLowerCase();
  const llm = await i.confirm(
    'Enable LLM Support',
    'atomi/llm',
    'Add CLAUDE.md and Claude skills',
  );
  const docker = await i.confirm('Enable Docker', 'atomi/docker', 'Enable Docker Integration');
  const helm = await i.confirm('Enable Helm', 'atomi/helm', 'Enable Helm Chart Integration');
  const secret = await i.confirm(
    'Enable Secret Management',
    'atomi/secret',
    'Enable Secret Management',
  );

  return { platform, service, llm, docker, helm, secret };
}
