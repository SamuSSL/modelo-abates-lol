# Dota 2 Team Identity Resolution

## Context

O catálogo Dota atual identifica equipes por `team_id` OpenDota. Isso preserva a integridade histórica, mas expõe duas identidades com o mesmo nome sem explicar qual representa a equipe operacional atual. O problema é agravado por mudanças de elenco e por novos IDs para a mesma organização.

O catálogo atual contém `team_id`, `team_name`, `map_count` e `last_seen`, mas não contém uma camada de versão do elenco. A auditoria local também confirma que os jogadores disponíveis em payloads OpenDota são observados depois da partida. O endpoint OpenDota `/teams/{team_id}/players` fornece uma fotografia de membros atuais no momento da coleta. Ambas as fontes são evidência temporal, não confirmação automática do elenco futuro.

## Objetivo

Permitir que a simulação selecione uma identidade operacional por nome, data e evento sem misturar silenciosamente históricos de equipes diferentes. A seleção automática deve ser útil, mas qualquer falta de evidência atual deve aparecer claramente e reduzir a confiança operacional.

## Decisões

1. `opendota_team_id` continua sendo a chave histórica imutável. IDs diferentes nunca são fundidos automaticamente.
2. `canonical_team_name` é uma camada operacional de apresentação e agrupamento, não substitui o ID histórico.
3. A resolução usa somente evidência com `observed_at` anterior ao `scheduled_start` da simulação.
4. A resolução operacional escolhe a identidade mais recente anterior ao cutoff, com maior evidência histórica como desempate.
5. A idade da identidade continua sendo reportada em três estados: `fresh` até 45 dias, `aging` de 46 a 90 dias e `stale` acima de 90 dias.
6. Evidências de roster continuam disponíveis apenas para auditoria histórica. Elas não são usadas para bloquear a simulação ou a comparação manual.
7. Uma mudança observada de quatro jogadores em cinco continua podendo ser registrada como `new_roster_version`, mas essa classificação não altera a decisão operacional.
8. Uma identidade `stale` ou com roster incompleto continua podendo gerar a linha, desde que exista um ID OpenDota elegível antes do cutoff.
9. A interface não oferece override de identidade histórica: o fluxo operacional usa apenas o ID mais recente elegível. A conferência do elenco é manual e externa ao modelo.

## Contrato de dados

O registro operacional terá:

```text
canonical_team_name
opendota_team_id
last_seen
map_count
last_observed_roster
last_observed_roster_members
last_roster_observed_at
roster_snapshot_count
previous_roster_overlap
roster_status
identity_status
source
roster_evidence_retrieved_at
```

`last_observed_roster` é uma lista de IDs de jogadores extraída de partidas concluídas. Ela só pode ser usada como evidência disponível depois daquela partida e antes de uma previsão posterior.

## Resolução

Para um nome operacional e `scheduled_start`:

1. Filtrar candidatos cujo `last_seen <= scheduled_start`.
2. Priorizar registro aprovado para o evento, se existir.
3. Caso contrário, ordenar por `last_seen` decrescente.
4. Calcular idade da evidência em relação ao cutoff.
5. Se houver candidatos próximos no tempo ou divergência de identidade, marcar `ambiguous`.
6. Retornar o ID selecionado, a regra usada e a evidência. Bloquear somente quando não houver ID elegível.

O resolvedor nunca consulta partidas posteriores ao cutoff para escolher o ID ou roster. A seleção de um evento futuro pode usar uma associação editorial/manual registrada, mas não pode transformar a lista de participantes em confirmação de jogadores.

## Interface

O seletor principal mostrará um único item por `canonical_team_name`, com o ID histórico mais recente:

```text
Hokori · ID automático 10150267 · último histórico 2026-06-17
```

A interface não exibirá membros observados, titulares, reservas ou treinadores. A idade do ID poderá ser mostrada como informação, mas não como bloqueio.

## Integração com o modelo

As oito features operacionais continuam as mesmas. A camada de identidade apenas decide qual histórico point-in-time pode alimentar a previsão e expõe metadados de qualidade. Não serão adicionados heróis, draft, side, itens ou eventos do mapa.

Quando a evidência do elenco estiver `stale`, `ambiguous`, `current_membership_incomplete` ou `new_roster_version`, o sistema não inventará dados nem fundirá IDs. Ele continuará usando o ID mais recente elegível; a decisão de evitar a aposta por mudança de elenco será manual.

## Testes e critérios de aceitação

- Dois IDs com o mesmo nome viram um único item operacional e mantêm duas alternativas históricas.
- O ID posterior ao cutoff nunca é escolhido.
- A identidade mais recente é escolhida quando não existe associação de evento aprovada.
- Evidência acima de 90 dias recebe `stale`.
- Uma troca de quatro jogadores em cinco recebe `new_roster_version`.
- Roster pós-jogo é tratado como `last_observed_roster`, não como confirmação futura.
- Um ID de roster incompleto não bloqueia a comparação manual quando a identidade OpenDota foi resolvida.
- Nenhum ID elegível antes do cutoff bloqueia a comparação manual.
- O pipeline Python existente continua passando.
- O Streamlit mostra o ID selecionado e o último histórico antes do cálculo, sem exibir roster.

## Fora de escopo

Esta alteração não promete descobrir automaticamente o elenco confirmado de um evento quando OpenDota e BettingIsCool não o fornecem. Nessa situação, o sistema deve declarar a limitação e manter a simulação em estado de baixa confiança/revisão.
