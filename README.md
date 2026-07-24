# LoL Kills V1

Modelo probabilístico pós-draft para o total de kills de mapas
profissionais de League of Legends.

## Estado

O treinamento e a avaliação são feitos em R. A interface pública usa
Streamlit e executa um bundle congelado com paridade numérica testada.
Dados brutos do Oracle's Elixir não fazem parte do repositório.

V1 pública:
https://modelo-abates-lol-sry25k3zh76r7ffs2qo8m3.streamlit.app/

## Aplicação local

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m streamlit run streamlit_app.py
```

O arquivo `app_data/model_bundle.json` precisa existir. Para persistência
durável, configure uma URL PostgreSQL conforme
`.streamlit/secrets.toml.example`.

## Testes

```powershell
Rscript -e "pkgload::load_all(); testthat::test_dir('tests/testthat')"
python -m pytest tests_python -q
```

## Limite de uso

O modelo estima probabilidades; não garante resultados. Uma entrada com
amostra insuficiente retorna `blocked` e a mensagem “Não apostar”.
