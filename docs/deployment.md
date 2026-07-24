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

O caso `ok` foi validado no ambiente público. Enquanto o segredo
PostgreSQL não for configurado, a aplicação usa SQLite temporário. Esse
arquivo pode desaparecer quando o Streamlit reiniciar o processo.

Referências oficiais:

- https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/deploy
- https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/secrets-management
- https://docs.streamlit.io/deploy/streamlit-community-cloud/deploy-your-app/app-dependencies
