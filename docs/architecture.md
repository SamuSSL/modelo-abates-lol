# Arquitetura

## Revisão para Streamlit público

O deploy da V1 usa esta arquitetura:

```text
R: treino, validação e promoção
  -> bundle portátil imutável
  -> Python: inferência equivalente
  -> Streamlit público
  -> PostgreSQL externo append-only
```

O bundle contém coeficientes, dispersão, padronização, níveis de liga, PMF,
taxonomia, catálogos, limites, cutoff e hashes. Python não treina nem ajusta o
modelo. Ele apenas executa fórmulas congeladas. Fixtures douradas comparam PMF,
média, intervalos, Over, Under, odds e EV entre R e Python.

`plumber` continua disponível localmente para diagnóstico e contrato, mas o
Streamlit público não depende de um segundo processo R. Isso reduz serviços,
latência e pontos de falha.

O app usa caminhos portáteis com `/`, `requirements.txt`,
`.streamlit/config.toml` e secrets do ambiente. Persistência pública usa
PostgreSQL; DuckDB continua para pesquisa e execução local.

O Community Cloud executa apps a partir da raiz do repositório em Debian Linux
e instala dependências Python e externas declaradas:

- [Organização de arquivos](https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/file-organization)
- [Dependências](https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/app-dependencies)
- [Secrets](https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/secrets-management)

## Visão geral

O projeto será organizado como um projeto R com funções modulares, `testthat`, `renv`, `targets`, scripts RStudio e API `plumber`. Scripts e pipeline chamam as mesmas funções; não haverá duas implementações da lógica estatística.

```text
CSV local
  -> manifesto e validação
  -> tabelas canônicas
  -> séries e cutoffs
  -> features históricas
  -> folds temporais
  -> treino e avaliação
  -> bundle imutável aprovado
  -> API plumber
  -> snapshot append-only
  -> reconciliação com resultado
```

## Estrutura planejada

```text
.
├── DESCRIPTION
├── NAMESPACE
├── renv.lock
├── .Rprofile
├── _targets.R
├── config/
├── data/
├── docs/
├── R/
│   ├── ingest/
│   ├── validation/
│   ├── features/
│   ├── archetypes/
│   ├── models/
│   ├── evaluation/
│   ├── inference/
│   ├── storage/
│   └── utils/
├── scripts/
├── tests/
├── reports/
├── artifacts/
├── models/
├── api/
└── clients/
```

Diretórios só serão criados quando receberem conteúdo real.

## Camadas

### Configuração

Arquivos YAML versionados definem:

- ligas e mapeamentos históricos;
- aliases aprovados;
- campos e versões de schema;
- regras de elegibilidade;
- folds e janelas candidatas;
- seeds;
- taxonomia e regras de composição;
- limites de amostra aprovados;
- tolerâncias probabilísticas;
- versões ativas.

Configuração nunca contém caminho absoluto.

### Ingestão

Responsável por manifesto, hash, leitura por temporada e adaptação de schema. Não aplica lógica estatística.

### Validação e normalização

Produz tabelas canônicas, entidades, séries, cutoffs e eventos de qualidade. Não descarta silenciosamente linhas.

### Features

Recebe tabelas canônicas e um conjunto explícito de cutoffs. Toda função exige `as_of` ou estrutura equivalente. Caches incluem hash do cutoff e dados.

### Arquétipos

Carrega taxonomia aprovada, valida período do campeão, calcula scores de composição e retorna explicação determinística.

### Modelos

Cada candidato implementa interface comum:

```text
fit_model(train_data, config)
predict_pmf(model, new_data, config)
model_diagnostics(model)
serialize_model(model, destination)
```

### Avaliação

Constrói folds, reexecuta todo o preprocessamento dentro do treino, armazena previsões out-of-fold e calcula métricas.

### Inferência

Valida input, resolve entidades, verifica amostra, gera features no cutoff do bundle, classifica composições, produz PMF e calcula mercado.

### Persistência

Um banco DuckDB local mantém snapshots e liquidações append-only. Atualizações de reconciliação criam novos registros ou status versionados; não sobrescrevem o snapshot original.

## Scripts RStudio

Os scripts planejados são:

```text
00_restore_environment.R
01_register_raw_data.R
02_audit_and_normalize.R
03_build_canonical_games.R
04_build_features.R
05_run_eda.R
06_build_taxonomy.R
07_train_baselines.R
08_train_candidates.R
09_evaluate_models.R
10_promote_model.R
11_run_api.R
12_reconcile_predictions.R
```

Cada script:

- descobre a raiz do projeto;
- carrega configuração;
- chama funções em `R/`;
- falha com mensagem clara;
- não muda o diretório global permanentemente;
- pode ser executado isoladamente depois de suas dependências declaradas.

## Pipeline `targets`

O pipeline reproduz as mesmas etapas e torna explícitas dependências entre:

- manifestos;
- dados canônicos;
- auditorias;
- folds;
- features;
- taxonomia;
- candidatos;
- métricas;
- relatórios;
- bundle.

Treinos caros usarão branches e armazenamento persistente. Artefatos de candidatos rejeitados continuam rastreáveis.

## Armazenamento

### Dados analíticos

- DuckDB para consultas e joins locais;
- Parquet para artefatos tabulares portáveis;
- CSV apenas como input bruto ou exportação explícita.

### Modelos

Bundles imutáveis em diretórios versionados. Um ponteiro de configuração indica o bundle ativo; promoção não reescreve o bundle.

### Predições

DuckDB append-only, com snapshot JSON canônico e colunas indexáveis para evento, data, liga, linha, versão e lado apostado.

## API local

### `POST /v1/predict`

Valida o contrato, gera ou bloqueia a previsão, persiste o snapshot e retorna o resultado.

### `GET /v1/metadata`

Retorna catálogos válidos, versão ativa, cutoff, posições, ligas, limites e schema da requisição.

### `GET /health`

Verifica processo, bundle carregado, banco gravável e compatibilidade de schema. Não executa treino.

O processo carrega o bundle uma vez na inicialização. Uma requisição não executa MCMC nem retreina modelos.

## Cliente Python

Um cliente mínimo:

- valida o JSON básico;
- chama a API;
- trata timeout de 30 segundos mais margem de rede local;
- valida a versão do contrato;
- diferencia erro de input, bloqueio estatístico e falha do serviço.

Não haverá reimplementação da estatística em Python.

## Identificador do evento

O `event_id` será um hash estável de uma representação canônica contendo:

```text
league
scheduled_datetime_utc
unordered_team_ids
map_number
contract_version
```

Mudança material no horário poderá criar alias de evento durante reconciliação. Vínculo aproximado nunca liquida automaticamente sem score de confiança suficiente.

## Observabilidade

Logs estruturados devem registrar:

- execução e versão;
- duração por etapa;
- contagens;
- códigos de qualidade;
- treino e diagnósticos;
- latência da API;
- bloqueios e warnings;
- falhas de persistência;
- reconciliações automáticas e pendentes.

Inputs pessoais ou segredos não são esperados. O log não duplicará payloads completos quando o snapshot já existir.

## Falhas e recuperação

- Hash divergente bloqueia ingestão.
- Schema desconhecido bloqueia a temporada afetada.
- Série ambígua bloqueia features desses mapas.
- Bundle não aprovado impede inicialização em modo produção.
- Falha ao persistir impede resposta `ok`, evitando consulta não registrada.
- Falha de reconciliação cria pendência, nunca um resultado inventado.
- Um rollback troca o ponteiro ativo para bundle anterior aprovado.

## Versionamento

Versionar separadamente:

- contrato da API;
- schema canônico;
- features;
- taxonomia;
- dataset;
- modelo;
- configurações de avaliação.

Mudança incompatível no JSON exige nova versão do endpoint.
