# Contribuindo com o fwsec

O repositório aceita contribuições por pull request. Não faça push direto para `main`.

## Fluxo obrigatório

1. Crie uma branch a partir da `main`.
2. Faça uma alteração pequena e autocontida.
3. Execute as validações aplicáveis.
4. Atualize a documentação quando o comportamento público mudar.
5. Abra um pull request descrevendo mudança, motivação, impacto e testes.
6. Solicite a revisão de `@hdbrsaulobrito`.

Todo arquivo pertence a `@hdbrsaulobrito` por meio do `CODEOWNERS`. Somente a aprovação desse mantenedor satisfaz o requisito de revisão para merge na branch protegida.

## Validação mínima

```bash
python3 -m compileall -q src
bash -n install.sh
```

Quando disponíveis, execute também:

```bash
ruff check src
mypy src
```

## Segurança

Não inclua credenciais, tokens, IPs internos, dados de clientes ou configurações reais. Vulnerabilidades devem seguir o processo descrito em [SECURITY.md](SECURITY.md), sem issue pública.
