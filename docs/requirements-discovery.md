# Descoberta de requisitos

## Revisão aprovada após início da implementação

- Reworks não serão modelados na V1.
- Uma taxonomia estática baseada na definição de 2026 será aplicada a
  2022–2026.
- Resultados do holdout 2026 não podem alimentar features históricas.
- Streamlit visual e deploy público agora fazem parte da V1.
- Treinamento permanece em R; inferência pública usa bundle portátil em Python
  com paridade obrigatória.
- Persistência pública usa PostgreSQL externo via secret.

## Situação

Este documento registra as decisões tomadas antes da implementação do modelo pós-draft de total de kills. Ele é a fonte de verdade para o escopo do produto. Os documentos técnicos em `docs/` detalham como essas decisões serão implementadas e testadas.

Status da descoberta: concluída, aguardando aprovação explícita do conjunto SDD.

## Objetivo e usuário

O produto será usado localmente por uma única pessoa para estimar, depois do draft e antes do início de um mapa profissional de League of Legends:

- a distribuição completa do total de kills;
- as probabilidades de Over e Under para uma linha terminada em `.5`;
- as odds decimais justas;
- o EV para as odds de mercado fornecidas;
- a confiança e os motivos de eventuais alertas ou bloqueios.

O objetivo estatístico primário é qualidade probabilística fora da amostra. Sem odds históricas confiáveis, a primeira promoção não fará alegações de lucro histórico.

## Decisões aprovadas na descoberta

### Dados

- A fonte principal será Oracle's Elixir.
- Os arquivos serão fornecidos localmente. O projeto não fará download automático.
- O conjunto esperado cobre 2022 a 2026.
- Cada arquivo recebido terá hash, temporada, nome original, tamanho e data de recebimento registrados.
- Registros marcados como `partial` poderão ser usados quando possuírem todos os campos exigidos pelo módulo correspondente.
- Dados brutos não serão alterados nem versionados no Git.
- O pipeline deve validar o schema efetivamente recebido antes de qualquer modelagem.

### Escopo competitivo

- Ligas-alvo: LCK, LPL, LEC, CBLOL, LCS, LFL e LES.
- `LES` representa a Liga Española e terá continuidade histórica com `LVP SL`.
- Em 2025, LTA North será associada ao histórico da LCS e LTA South ao histórico do CBLOL.
- Confrontos cruzados da LTA serão tratados como histórico auxiliar.
- Torneios internacionais poderão atualizar histórico de equipes e jogadores, mas não serão ligas-alvo.
- Outras ligas Academy, Challengers e ERLs ficam fora do treino principal e da inferência.

### Unidade prevista e target

- Cada previsão corresponde a um mapa, nunca ao total de uma série.
- O target é `team_a_kills + team_b_kills`, calculado uma única vez a partir das duas linhas de equipe.
- Kills de jogadores e deaths serão usadas para validação, não somadas novamente ao target.
- Remakes, forfeits e partidas interrompidas serão excluídos por evidência documentada.
- Não será adotado um corte fixo de duração antes da auditoria, pois jogos curtos podem ser válidos.

### Cutoff temporal

- A previsão representa o instante posterior ao draft e anterior ao início do mapa.
- As features de todos os mapas de uma série serão congeladas no estado anterior ao primeiro mapa da série.
- Nenhuma informação produzida durante a série poderá atualizar as features dos mapas posteriores.
- Toda transformação supervisionada e todo encoding serão ajustados apenas dentro do fold de treino.

### Inputs de draft e contexto

- A inferência exige cinco jogadores, cinco posições e cinco campeões para cada equipe.
- Side será informado explicitamente.
- Bans, ordem de picks, first pick, patch e fase regular/playoffs não serão features do modelo inicial.
- Patch e fase competitiva poderão ser conservados apenas para auditoria e avaliação segmentada.
- O sistema não fará chamadas a LLM em tempo de inferência.

### Mercado

- A primeira versão aceitará apenas linhas cujo componente fracionário seja `.5`.
- Linhas inteiras, `.25` e `.75` serão rejeitadas.
- `probability_push` será sempre zero.
- Odds decimais de Over e Under serão opcionais e independentes.
- EV será calculado somente para o lado cuja odd foi fornecida.
- Quando ambas as odds forem fornecidas, o sistema também mostrará probabilidades implícitas normalizadas sem vigorish.
- O sistema não recomendará stake. Quando uma aposta for registrada, a stake será fixa em 1 unidade.
- O lado efetivamente apostado será opcional. Sem lado registrado, o snapshot será apenas uma consulta.
- Bookmaker não será armazenado.

### Confiança e bloqueios

- Equipe, jogador ou campeão abaixo da amostra mínima bloqueará a previsão.
- O resultado bloqueado deverá identificar cada entidade insuficiente e mostrar `Pouca amostra para X. Não apostar`.
- Os limites mínimos serão definidos empiricamente na validação e armazenados em configuração versionada.
- Outros problemas de cobertura ou extrapolação não bloqueadores manterão a previsão, acompanhada de warnings e confiança reduzida.
- Campeão novo ou com rework material permanecerá bloqueado até atingir a cobertura mínima aprovada para sua versão.

### Operação

- Ambiente: Windows 10 de 64 bits, R nativo e Rtools.
- Dependências serão controladas com `renv`.
- O projeto usará funções modulares, um pipeline `targets` e scripts R numerados executáveis individualmente no RStudio.
- Treinamentos pesados poderão durar de 8 a 12 horas.
- A inferência individual poderá levar até 30 segundos.
- A integração futura com Streamlit será feita por API local `plumber`.
- O Streamlit visual não faz parte da primeira versão.
- Documentação, relatórios e mensagens serão escritos em PT-BR; código e schemas usarão inglês.

### Filosofia de modelagem

- A abordagem será simples primeiro.
- O modelo principal candidato usará pooling parcial por liga.
- CRPS será a métrica primária de ordenação.
- Calibração, Log Score e desempenho por liga serão guardrails obrigatórios.
- Modelos complexos só poderão ser promovidos com ganho temporal material, consistente e justificável.
- O submodelo de duração será challenger e não dependência obrigatória.
- Deep learning fica fora da primeira versão.
- O conjunto mínimo de experimentos ainda inclui baselines, Poisson, Negative Binomial, modelo hierárquico bayesiano, gradient boosting e ensemble probabilístico.

### Taxonomia de campeões

- A taxonomia será baseada em pesquisa web rastreável, não apenas em conhecimento geral.
- A revisão será feita em lotes por função.
- A cobertura incluirá todos os campeões observados de 2022 a 2026 e todos os campeões habilitados no período atual relevante.
- Reworks materiais terão versões próprias.
- O classificador de composição será determinístico, versionado, multi-label e explicável.

### Persistência prospectiva

- Toda previsão será salva automaticamente em armazenamento local append-only.
- O identificador do evento será derivado de liga, data/hora, equipes e número do mapa.
- Novas cargas de resultados tentarão reconciliar automaticamente eventos previstos.
- Métricas prospectivas usarão todos os snapshots válidos.
- ROI usará apenas snapshots marcados como aposta realizada, com lado informado e stake de 1 unidade.

## Alternativas descartadas

- Download automático de dados: descartado para manter controle manual dos arquivos usados.
- Previsão de série: descartada; o mercado inicial é por mapa.
- Push e linhas asiáticas: descartados da primeira versão.
- Atualização entre mapas da mesma série: descartada para evitar dependência de dados intrassérie.
- Patch como feature: descartado; recência deve absorver a mudança de meta no modelo inicial.
- Bans e ordem de draft: descartados por baixa relevância esperada e cobertura limitada.
- Modelos separados por liga como arquitetura principal: substituídos por pooling parcial, mantendo-os como comparação.
- Submodelo obrigatório de duração: descartado; será challenger.
- Interface por subprocesso R ou artefato reimplementado em Python: substituída por `plumber`.
- Inferência com fallback para entidades novas: descartada; pouca amostra será bloqueio duro.
- Bookmaker e stake variável: fora de escopo.

## Riscos conhecidos

- Os CSVs 2022–2026 ainda precisam ser entregues e auditados; schemas e cobertura podem divergir.
- O Oracle's Elixir pode conter linhas parciais, IDs ausentes, drafts incorretos ou mudanças de nomenclatura.
- A derivação de série pode ser ambígua quando não houver identificador estável.
- A regra de congelamento pré-série reduz leakage, mas não usa informação legitimamente disponível entre mapas.
- O bloqueio por amostra mínima pode reduzir bastante a cobertura operacional.
- A taxonomia funcional possui julgamento humano e precisa de revisão antes de uso.
- A ausência de patch no input pode reduzir adaptação a mudanças abruptas.
- Sem odds históricas não há base para afirmar rentabilidade retrospectiva.
- MCMC e alguns pacotes podem ser caros ou difíceis de instalar no Windows.

## Pendências que dependem de evidência

Estas pendências não autorizam decisão arbitrária durante a implementação:

- janela histórica e função de recência;
- limites mínimos de amostra por tipo de entidade;
- limites numéricos de calibração e degradação por liga;
- distribuição final e arquitetura campeã;
- utilidade incremental de jogadores, campeões, arquétipos e duração;
- taxonomia final aprovada;
- gatilhos de retreinamento e drift.

Cada decisão será produzida pelo experimento especificado, registrada em `decision-log.md` e submetida à aprovação antes da promoção.

## Critérios de aceite da descoberta

- Todas as decisões acima aparecem sem contradição nos documentos SDD.
- Requisitos possuem identificadores verificáveis.
- Dados proibidos no momento da previsão estão explícitos.
- O gate de aprovação antes do código está preservado.
- Pendências empíricas possuem procedimento de decisão, não valores inventados.
