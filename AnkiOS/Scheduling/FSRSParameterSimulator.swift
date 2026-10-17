import AnkiBackend
import Foundation

enum FSRSParameterSimulator {
    private struct Output: Decodable {
        var days: [FSRSSimulationDay]
    }

    private struct OutputError: Decodable {
        var error: String
    }

    static func compute(_ request: FSRSSimulationRequest) throws -> [FSRSSimulationDay] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        guard let input = String(data: data, encoding: .utf8) else { throw SimulationError.invalidInput }

        let rawOutput = input.withCString { ankios_fsrs_simulate($0) }
        guard let rawOutput else { throw SimulationError.invalidOutput }
        defer { ankios_fsrs_free_string(rawOutput) }

        let outputData = Data(String(cString: rawOutput).utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let failure = try? decoder.decode(OutputError.self, from: outputData) {
            throw SimulationError.failed(failure.error)
        }
        let result = try decoder.decode(Output.self, from: outputData)
        guard result.days.count == request.days,
              result.days.allSatisfy({ $0.studySeconds.isFinite && $0.memorized.isFinite }) else {
            throw SimulationError.invalidOutput
        }
        return result.days
    }

    enum SimulationError: LocalizedError {
        case invalidInput
        case invalidOutput
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .invalidInput: return "Não foi possível preparar os dados para simulação."
            case .invalidOutput: return "O simulador retornou dados inválidos."
            case let .failed(message): return message
            }
        }
    }
}
