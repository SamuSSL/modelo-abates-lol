# Contrato de dados

## Princípios

- Arquivos de origem são imutáveis.
- Nenhum caminho absoluto faz parte de código, configuração versionada ou artefato.
- Toda tabela derivada deve ser rastreável até hashes dos arquivos brutos, versão do código e configuração.
- Dados permitidos na modelagem devem existir antes do cutoff definido para a série.

## Origem e manifesto

Os CSVs do Oracle's Elixir serão colocados manualmente em `data/raw/oracles_elixir/`. Um manifesto versionado de estrutura, mas preenchido localmente para cada carga, deve registrar:

```text
source_name
season
file_name
sha256
size_bytes
received_at
declared_source_url?
schema_version
ingestion_status
```

O pipeline não aceita silenciosamente:

- arquivo ausente no manifesto;
- hash alterado;
- temporada duplicada sem uma revisão explícita;
- arquivo vazio;
- header incompatível sem adapter de schema.

## Granularidade esperada

Um mapa normalmente contém:

- dez linhas de jogador;
- duas linhas de equipe;
- um `gameid`;
- dois sides;
- cinco posições por equipe;
- um campeão por jogador.

O valor `datacompleteness` não decide sozinho a elegibilidade. Cada módulo possui campos obrigatórios próprios.

## Chaves canônicas

### Mapa

`game_key` usa o identificador estável de origem quando disponível. Fallbacks derivados precisam ser marcados com `key_quality = "derived"` e não podem colidir dentro de uma carga.

### Série

Ordem de preferência:

1. identificador estável de série presente na origem;
2. URL ou identificador de confronto compartilhado pelos mapas;
3. chave derivada por liga, data local, par não ordenado de equipes e sequência compatível de mapas.

Séries ambíguas devem ser enviadas para relatório de exceções. Não podem ser usadas para features enquanto a ambiguidade permanecer.

### Entidades

- `team_id`, `player_id` e IDs de origem são preferidos a nomes.
- Aliases são mantidos em configuração versionada com período de validade.
- Rebranding não cria fusão automática quando o ID ou a continuidade competitiva forem incertos.
- Nome original e nome canônico permanecem disponíveis.

## Mapeamento de ligas

```text
LCK -> LCK
LPL -> LPL
LEC -> LEC
CBLOL -> CBLOL
LCS -> LCS
LFL -> LFL
LVP SL -> LES
LES -> LES
LTA North (2025) -> LCS
LTA South (2025) -> CBLOL
```

Confrontos cruzados da LTA e torneios internacionais recebem `competition_role = "auxiliary"`. Eles podem atualizar histórico anterior ao cutoff, mas não entram nas métricas primárias das sete ligas.

Mapeamentos de 2025 dependerão da inspeção dos valores reais do CSV. O adapter deve usar competição, equipes e metadados do evento; nunca deve classificar apenas pelo texto `LTA` sem evidência da conferência.

## Schema mínimo de ingestão

O adapter deve localizar equivalentes versionados para:

```text
gameid
datacompleteness
league
year
split
playoffs
date
game
patch
participantid
side
position
playername
playerid
teamname
teamid
champion
gamelength
kills
deaths
teamkills
teamdeaths
```

Patch, playoffs e bans podem ser ingeridos para auditoria, mas não podem entrar na matriz de features do modelo.

## Tipos e domínios

- Datas são normalizadas para UTC, preservando o texto e timezone declarados na origem.
- `map_number`, kills, deaths e duração são inteiros não negativos.
- Side aceita apenas `Blue` e `Red` após normalização.
- Posições canônicas: `top`, `jng`, `mid`, `bot`, `sup`, além de `team` para linhas agregadas.
- Cada equipe deve possuir cinco jogadores e cinco campeões únicos.
- Um campeão não pode aparecer nas duas equipes do mesmo mapa.
- Team kills e player kills devem ser inteiros e internamente consistentes.

## Construção do target

Para cada mapa elegível:

1. selecionar exatamente duas linhas de equipe, uma por side;
2. obter `teamkills` de cada linha;
3. calcular `total_kills_game = blue_teamkills + red_teamkills`;
4. validar cada `teamkills` contra a soma das kills dos cinco jogadores da equipe;
5. validar `total_kills_game` contra a soma das deaths dos dez jogadores quando deaths estiverem completas;
6. nunca somar kills e deaths no target.

Uma divergência não corrigível torna o mapa inelegível e produz um registro de qualidade com os valores conflitantes.

## Elegibilidade por módulo

### Target e histórico de equipe

Exige:

- duas equipes e sides distintos;
- target validado;
- data e ordem temporal resolvidas;
- duração válida para auditoria;
- não ser remake, forfeit ou mapa interrompido.

### Histórico de jogador

Além do target, exige:

- dez jogadores identificáveis;
- cinco posições válidas por equipe;
- IDs ou aliases resolvidos.

### Draft e taxonomia

Além do histórico de jogador, exige:

- dez campeões válidos e únicos;
- versão de taxonomia aplicável à data;
- ausência de ambiguidade de posição.

Um mapa pode participar de um módulo e não de outro. Cobertura e motivos de exclusão devem ser reportados separadamente.

## Remakes, forfeits e interrupções

A exclusão usa, em ordem:

- flag explícita da origem;
- lista de exceções versionada com evidência;
- inconsistência estrutural inequívoca;
- regra aprovada posteriormente após auditoria.

Duração curta isolada não é evidência suficiente. Casos excluídos preservam os dados e o motivo.

## Cutoff e prevenção de leakage

O cutoff de uma série é o instante imediatamente anterior ao primeiro mapa. Todas as observações da própria série ficam fora do histórico de todos os seus mapas.

Cada registro de feature deve carregar:

```text
feature_as_of
series_cutoff
source_max_event_time
```

Deve valer:

```text
source_max_event_time < series_cutoff
feature_as_of <= series_cutoff
```

São proibidos como features:

- duração observada do mapa previsto;
- kills, deaths, gold, objetivos, resultado ou qualquer estatística do mapa previsto;
- dados de mapas anteriores da mesma série;
- lineup corrigida ou publicada apenas depois do início;
- odds e resultados de mercado;
- patch, playoffs e bans, por decisão de produto.

## Tabelas analíticas

### `games`

Uma linha por mapa com target, contexto, cutoff, elegibilidade e chaves.

### `game_teams`

Duas linhas por mapa com equipe, side, target da equipe e contexto.

### `game_players`

Dez linhas por mapa com jogador, posição, campeão e apenas estatísticas históricas permitidas para construção posterior de features.

### `series`

Uma linha por série com método e qualidade da chave, cutoff e mapas pertencentes.

### `entity_aliases`

Aliases com entidade canônica, validade temporal, fonte e status de revisão.

### `quality_events`

Falhas e warnings com código, entidade, arquivo, chave e valores relevantes.

### `prediction_snapshots`

Tabela append-only de inputs, outputs, modelo, cutoff e aposta opcional.

### `settlements`

Resultados reconciliados, status de liquidação, P&L de stake unitária e método de vínculo.

## Versionamento

Cada dataset processado recebe:

- hash combinado dos arquivos brutos;
- versão do adapter;
- versão do mapeamento de ligas e aliases;
- versão da taxonomia;
- commit ou hash do código;
- horário de construção;
- contagens e checksums das tabelas principais.

## Aceite do contrato

- Todos os CSVs fornecidos possuem manifesto e hash válido.
- Mudanças de schema produzem erro explícito ou adapter testado.
- O target passa nas validações cruzadas.
- Nenhum registro com série ambígua gera features.
- A auditoria explica toda exclusão.
- Um teste artificial com dado futuro falha antes do treino.

