# Deploy público da V1

## Arquitetura

R continua responsável por dados, treino, seleção, holdout e exportação.
O Streamlit lê apenas o bundle promovido e não precisa dos CSVs brutos.
Isso reduz o tamanho do deploy e remove a necessidade de um servidor R
público separado.

## Arquivos públicos

- `streamlit_app.py`: interface.
- `app/`: inferência e persistência.
- `app_data/model_bundle.json`: modelo, taxonomia e snapshots.
- `requirements.txt`: dependências Python.
- `.streamlit/config.toml`: tema e configuração.

## Persistência

Em desenvolvimento, eventos são anexados a SQLite local. No deploy,
configure:

```toml
[database]
url = "postgresql://user:password@host:5432/database?sslmode=require"
```

O segredo deve ser inserido no painel do Streamlit Community Cloud.
Nunca deve entrar no Git.

Na V1 pública, o PostgreSQL é fornecido pelo projeto Supabase exclusivo
`modelo-abates-lol`. Ele não compartilha banco com outros projetos. O aplicativo usa
o Transaction Pooler na porta 6543 e um papel próprio chamado
`lol_kills_writer`. Esse papel possui apenas `SELECT` e `INSERT` nas
tabelas `lol_kills.prediction_events` e `lol_kills.bet_decisions`; não
possui `UPDATE` nem `DELETE`. O schema, as tabelas, as políticas RLS e os
grants reproduzíveis estão nas migrações da pasta `sql/`. A senha do papel
não pertence às migrações e existe somente nos Secrets do Streamlit.

## Publicação

1. Criar repositório GitHub e enviar somente arquivos permitidos.
2. No Streamlit Community Cloud, selecionar o repositório, a branch e
   `streamlit_app.py`.
3. Inserir o segredo PostgreSQL.
4. Publicar.
5. Validar um caso `ok`, um caso `blocked`, persistência e acesso móvel.

## Estado da V1

Aplicação publicada em:
https://modelo-abates-lol-sry25k3zh76r7ffs2qo8m3.streamlit.app/

O caso `ok` foi validado no ambiente público. O segredo PostgreSQL está
configurado no Streamlit Community Cloud e a aplicação grava no projeto
Supabase exclusivo `modelo-abates-lol`.

A coleta prospectiva começou em 2026-07-25. A primeira validação após a
configuração gravou um evento `ok` em
`lol_kills.prediction_events`, sem aposta confirmada.

A interface salva primeiro a previsão. Somente depois de mostrar as
probabilidades ela oferece as decisões Over, Under ou Não apostar. A decisão
é gravada separadamente em `lol_kills.bet_decisions`.

Desde a reconstrução de 2026-07-25, a interface recebe apenas equipes e os
cinco campeões por posição de cada lado. Jogadores não entram no payload, no
bundle, nos limites de amostra nem no modelo. As linhas de jogador do Oracle's
Elixir continuam restritas à auditoria do target e à leitura do draft.

Referências oficiais:

- https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/deploy
- https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/secrets-management
- https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/app-dependencies
