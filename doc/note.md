 Now I understand the layout. The problem is that `CollapsingHeader` is **not a tab-stop** ^T it receives nav focus via arrow keys but Tab/Shift+Tab completely skips it. So Tab focus jumps from the multiline input directly past the header, and vice versa.

 The fix is to make the header a tab-stop by pairing it with an invisible button:

 ```cpp
 ImGui::BeginChild("output");

 bool open = true;
 ImGui::PushID("my_header");

 // Make the header a tab-stop by overlaying an invisible button
 ImGui::PushStyleVar(ImGuiStyleVar_Alpha, 0.0f);
 ImGui::Button("##tabstop", ImVec2(-1, 0));
 ImGui::PopStyleVar();

 if (ImGui::IsItemFocused() && (ImGui::IsKeyPressed(ImGuiKey_Space) ||
                                 ImGui::IsKeyPressed(ImGuiKey_Enter) ||
                                 ImGui::IsKeyPressed(ImGuiKey_NavGamepadActivate)))
 {
     open = !open;
 }

 // Restore alpha for the actual header
 ImGui::SetNextItemOpen(open, ImGuiCond_Always);
 ImGui::CollapsingHeader("some header");

 // Optionally handle the close button overlap
 ImGui::SameLine();

 ImGui::PopID();
 ImGui::EndChild();

 ImGui::BeginChild("input");
 ImGui::InputTextMultiline("##text", buf, sizeof(buf), size);
 ImGui::EndChild();
 ```

 **How this works:**
 - The invisible `Button` is a tab-stop, so Tab/Shift+Tab will land on it
 - When it's focused, Space/Enter toggles the header open/closed (just like clicking the header)
 - `Alpha = 0.0f` makes the button completely invisible but still focusable
 - `ImVec2(-1, 0)` makes the button stretch to fill the width with default height

 **Alternative (cleaner, if you don't need the toggle via Space):**

 If you just want Tab to skip focus *through* the header to the multiline and back without stopping, you don't need to do anything ^T that already works by default. The issue only exists if you want to **stop** at the header. If you just want seamless Tab between the two child windows, make sure neither child has `ImGuiWindowFlags_NoNavInputs`.

 **Another alternative ^T replace CollapsingHeader entirely:**

 ```cpp
 // A button that acts as a collapsible header
 bool open = true;
 ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0, 0, 0, 0));
 ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImGui::GetStyleColorVec4(ImGuiCol_HeaderHovered));
 ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImGui::GetStyleColorVec4(ImGuiCol_HeaderActive));
 if (ImGui::Button("� some header##toggle", ImVec2(-1, 0)))
     open = !open;
 ImGui::PopStyleColor(3);
 ImGui::PopStyleColor();

 if (open) {
     // header contents
 }
 ```

 This is a tab-stoppable, focusable "header" that toggles on click or Space activation.
