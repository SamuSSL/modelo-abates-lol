# Resolução de identidade e elenco do Dota 2

## Resultado da primeira coleta

O registro foi construído com os times presentes no catálogo operacional e consultou o endpoint OpenDota `/teams/{team_id}/players`. Cada resposta foi preservada no projeto fonte com endpoint, parâmetros, horário UTC de coleta, status HTTP, SHA-256 e versão de schema.

Resumo da coleta:

| Situação | Times |
|---|---:|
| Cinco membros atuais observados | 9 |
| Membros atuais incompletos | 34 |
| Sem evidência de roster | 137 |
| Total no registro | 180 |

## Hokori

| ID OpenDota | Último jogo histórico | Membros atuais observados | Situação |
|---|---|---:|---|
| `10150267` | 17/06/2026 | 2/5 | `current_membership_incomplete` |
| `7119077` | 13/04/2026 | 4/5 | `current_membership_incomplete` |

O sistema escolhe automaticamente o ID com evidência histórica mais recente antes do cutoff, mas mantém os dois IDs separados. Como o elenco atual não está completo, a simulação pode ser calculada para pesquisa, porém recebe bloqueio de comparação manual.

## Regra operacional

- Um nome visual, como `Hokori`, aparece uma vez no seletor principal.
- O ID OpenDota escolhido é mostrado no rótulo e nos metadados da previsão.
- A escolha automática respeita o horário planejado e nunca usa um `last_seen` posterior ao cutoff.
- O usuário pode abrir a identidade histórica avançada e selecionar um ID específico.
- A seleção manual é registrada como `manual_historical_override`.
- Elenco com menos de cinco membros observados não é tratado como elenco confirmado.
- Identidade stale, ambígua ou com elenco incompleto bloqueia a comparação manual.

## Limitação que permanece

`/teams/{team_id}/players` é uma fotografia do que o OpenDota reportou no momento da coleta. A resposta não garante que os cinco jogadores participarão do próximo mapa da PGL. Por isso, o sistema distingue `current_membership_observed` de confirmação do elenco do evento.

Quando a fonte não fornecer cinco jogadores atuais ou uma associação específica ao evento, o resultado correto é baixa confiança/revisão, e não a mistura silenciosa de históricos.

## Atualização do registro

A atualização deve ser executada no projeto fonte Dota 2, que preserva o cache bruto das respostas OpenDota:

```powershell
cd "C:\Users\Samuel\Documents\Modelo Abates Dota 2"
py -3 scripts/74_build_dota_team_identity_registry.py `
  --catalog-path "C:\Users\Samuel\Documents\Modelo Abates LoL\app_data\dota_ui_catalog.json" `
  --refresh-live
Copy-Item artifacts/team_identity/dota_team_identity_registry.json `
  "C:\Users\Samuel\Documents\Modelo Abates LoL\app_data\dota_team_identity_registry.json"
```

O comando consulta apenas os IDs do catálogo operacional, usa cache retomável e não grava a chave do BettingIsCool. Depois da cópia, a suíte `py -3 -m pytest tests_python -q` deve ser executada no projeto do Streamlit.
