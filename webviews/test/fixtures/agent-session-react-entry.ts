import { createElement } from "react";
import { createRoot } from "react-dom/client";
import { AgentSessionApp } from "../../src/agent-session/react/main";

const container = document.getElementById("root");
if (!container) throw new Error("Missing controlled renderer root.");
createRoot(container).render(createElement(AgentSessionApp));
