# Contributing to AI Pocket Reference Code

This guide explains how to contribute supplementary notebooks to the
[AI Pocket Reference](https://github.com/VectorInstitute/ai-pocket-reference) project.

## Notebook Guidelines

1. **Naming Convention**

   - Name your notebook to match its corresponding pocket reference
   - Example: If contributing code for the LoRA pocket reference, name it `lora.ipynb`

2. **Directory Structure**

   - Place notebooks in the same book directory as their corresponding pocket reference
   - Example: If the pocket reference is in the CV book, the notebook goes in `notebooks/cv/`

3. **Notebook Structure**

   - Clear introduction explaining the purpose
   - Install required dependencies using `%pip install <python-dep>` commands at
     the start

4. **Code Quality**
   - Write clean, documented code
   - Ensure all code cells run in sequence

## Contributing Process

1. **Fork the Repository**

   ```bash
   # Clone your fork
   git clone https://github.com/YOUR_USERNAME/ai-pocket-reference-code.git
   cd ai-pocket-reference-code
   ```

2. **Install pre-commit**

   ```bash
   # Install and set up pre-commit hooks
   pip install pre-commit
   pre-commit install
   ```

   The pre-commit hooks help maintain consistent code quality across the contributed
   notebooks. These checks run automatically before each commit. Alternatively,
   run `make lint` and ensure all checks pass prior to submitting a Pull Request.

3. **Create a Pull Request**
   - Create a new branch for your notebook
   - Add your notebook to the appropriate directory
   - Submit a pull request and fill in the PR template

## License

By contributing, you agree that your work will be licensed under the MIT License.

## Questions

For questions or support, join our Discord community (#ai-pocket-reference channel).

---

Thank you for helping make AI knowledge more applicable to everyone!
