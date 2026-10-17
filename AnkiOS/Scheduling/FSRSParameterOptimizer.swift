import AnkiBackend
import Foundation

enum FSRSParameterOptimizer {
    private struct Input: Encodable {
        var items: [FSRSTrainingItem]
        var enableShortTerm: Bool
        var numRelearningSteps: Int
        var healthCheck: Bool
    }

    private struct OutputError: Decodable {
        var error: String
    }

    private struct Output: Decodable {
        var parameters: [Double]
        var health: Health?
    }

    struct Health: Decodable, Sendable {
        var logLoss: Double
        var rmseBins: Double
    }

    struct Result: Sendable {
        var parameters: [Double]
        var health: Health?
    }

    static func compute(items: [FSRSTrainingItem], enableShortTerm: Bool, numRelearningSteps: Int, healthCheck: Bool = false) throws -> Result {
        guard items.count >= 8 else {
            throw OptimizerError.insufficientHistory
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(Input(
            items: items,
            enableShortTerm: enableShortTerm,
            numRelearningSteps: numRelearningSteps,
            healthCheck: healthCheck
        ))
        guard let input = String(data: data, encoding: .utf8) else { throw OptimizerError.invalidInput }

        let rawOutput = input.withCString { ankios_fsrs_compute_parameters($0) }
        guard let rawOutput else { throw OptimizerError.invalidOutput }
        defer { ankios_fsrs_free_string(rawOutput) }

        let output = Data(String(cString: rawOutput).utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let failure = try? decoder.decode(OutputError.self, from: output) {
            throw OptimizerError.trainingFailed(failure.error)
        }
        let result = try decoder.decode(Output.self, from: output)
        guard result.parameters.count == 21, result.parameters.allSatisfy(\.isFinite) else { throw OptimizerError.invalidOutput }
        return Result(parameters: result.parameters, health: result.health)
    }

    enum OptimizerError: LocalizedError {
        case insufficientHistory
        case invalidInput
        case invalidOutput
        case trainingFailed(String)

        var errorDescription: String? {
            switch self {
            case .insufficientHistory: return "O histórico precisa ter pelo menos oito revisões para otimizar os parâmetros."
            case .invalidInput: return "Não foi possível preparar o histórico para otimização."
            case .invalidOutput: return "O otimizador retornou parâmetros inválidos."
            case let .trainingFailed(message): return message
            }
        }
    }
}
