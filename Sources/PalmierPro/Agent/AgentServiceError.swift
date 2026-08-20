enum AgentServiceError: Error {
    case unauthenticated
    case insufficientCredits(String)
    case unavailable(AgentModel)
    case refusal(AgentModel)
    case upstream(String)
}
