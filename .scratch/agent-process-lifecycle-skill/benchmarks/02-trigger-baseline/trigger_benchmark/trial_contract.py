from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .evidence_format import EvidenceValidationError, JsonValue, mapping, string, strings
from .fixture import FixtureIdentifierError, validate_fixture_id
from .models import Prompt, TrialRecord, Variant


@dataclass(frozen=True, slots=True)
class ExecutionContract:
    model: str
    agent: str
    output_format: str
    pure: bool
    python_major_minor: str

    def document(self) -> dict[str, JsonValue]:
        return {"model": self.model, "agent": self.agent, "format": self.output_format, "pure": self.pure, "python_major_minor": self.python_major_minor}


@dataclass(frozen=True, slots=True)
class TrialCommandContext:
    contract: ExecutionContract
    executable: str
    evidence_root: Path

    def validate(self, record: TrialRecord, prompt: Prompt, variant: Variant) -> None:
        if record.fixture_candidate_name != variant.skill_name:
            raise EvidenceValidationError("trial fixture identity does not match its candidate")
        try:
            fixture_id = validate_fixture_id(record.fixture_id)
        except FixtureIdentifierError as error:
            raise EvidenceValidationError("trial fixture identity is invalid") from error
        if len(record.command) != 12 or record.command[:10] != (self.executable, "run", "--pure", "--format", "json", "--model", self.contract.model, "--agent", "build", "--dir") or record.command[-1] != prompt.body:
            raise EvidenceValidationError("trial command does not match the execution contract or prompt")
        fixture_directory = Path(record.command[10])
        expected_fixture_directory = (self.evidence_root / "fixtures" / fixture_id).resolve()
        if not fixture_directory.is_absolute() or fixture_directory != fixture_directory.resolve() or fixture_directory != expected_fixture_directory:
            raise EvidenceValidationError("trial fixture directory does not match its retained identity")


def execution_contract(value: JsonValue | None) -> ExecutionContract:
    document = mapping(value, "execution_contract")
    if set(document) != {"model", "agent", "format", "pure", "python_major_minor"}:
        raise EvidenceValidationError("execution_contract has missing or unauthorized fields")
    contract = ExecutionContract(
        string(document.get("model"), "execution_contract.model"),
        string(document.get("agent"), "execution_contract.agent"),
        string(document.get("format"), "execution_contract.format"),
        document.get("pure") is True,
        string(document.get("python_major_minor"), "execution_contract.python_major_minor"),
    )
    if not contract.model or contract.agent != "build" or contract.output_format != "json" or not contract.pure:
        raise EvidenceValidationError("execution contract differs from the release protocol")
    return contract


def observed_executable(value: JsonValue | None) -> str:
    command = strings(mapping(value, "observed_environment.opencode").get("command"), "observed_environment.opencode.command")
    if len(command) != 2 or not command[0] or command[1] != "--version":
        raise EvidenceValidationError("observed OpenCode command identity is invalid")
    return command[0]
