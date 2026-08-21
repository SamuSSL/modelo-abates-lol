# Interface Sintética e Atualização Semanal

## Objetivo

Manter a aplicação pública exclusivamente como uma calculadora de Pinnacle sintética pré-abertura e preparar uma atualização semanal manual que atualize e publique o bundle sintético.

## Escopo da interface

- A única área visível será `Pinnacle sintética pré-abertura`.
- A interface não exibirá a previsão pós-draft, a referência Pinnacle pós-draft, o fallback dirigido, `Cotações soft`, `Apostas registradas` ou `Tracking temporal`.
- A interface não fará gravações em Supabase nem dependerá de `database.url` para calcular uma previsão sintética.
- A tela continuará aceitando uma cotação soft informada pelo usuário como comparação de EV. Essa cotação é entrada do cálculo, não um registro persistido.
- A cópia da página explicará que a linha e as odds Pinnacle são estimativas sintéticas pré-abertura, não cotações reais.

## Modelo e artefato de produção

- O artefato operacional será `app_data/synthetic_pinnacle_bundle.json`.
- `app_data/model_bundle.json` poderá continuar como dependência técnica de equipes quando necessário, mas não será apresentado como modelo ativo e não definirá a rotina de publicação.
- Uma atualização só poderá ser publicada se o bundle sintético, seu teste de paridade e a suíte de testes passarem.

## Atualizador semanal

- Um único script PowerShell será executado manualmente aos sábados a partir da raiz do projeto.
- Ele baixará o CSV de 2026 do link Google Drive fornecido, validará o arquivo antes de substituir o dado bruto e registrará o manifesto.
- Ele atualizará os dados necessários, executará o treinamento sintético, os testes de paridade e as suítes R e Python.
- Ele gravará um relatório datado em `Relatórios de atualização` com etapas, horários, versões, validações, publicação e erros.
- O relatório terminará com `Deu tudo certo!` apenas quando todas as etapas, incluindo a confirmação da publicação, forem concluídas.
- A publicação criará e enviará um commit contendo somente os artefatos gerados da Pinnacle sintética e seus arquivos de paridade. Alterações locais não relacionadas permanecerão fora do commit.

## Falhas e segurança

- CSV inválido, CSV sem atualização, falha da API BettingIsCool, treinamento, paridade, teste, commit, push ou confirmação de deploy interrompem a rotina.
- Em falha, o relatório registra a etapa e a mensagem de erro; não inclui `Deu tudo certo!`.
- Senhas, chaves e URLs sensíveis não serão gravadas no relatório, no repositório ou no script.
- A interface não tentará conectar ao Supabase após a remoção da persistência. A credencial exposta anteriormente deve ser rotacionada antes de qualquer uso futuro.

## Verificação

- Testes automatizados cobrirão as abas visíveis, a ausência de persistência na tela sintética e os caminhos de sucesso e erro do atualizador.
- A confirmação de publicação distinguirá push aceito no GitHub de interface atualizada no Streamlit.
