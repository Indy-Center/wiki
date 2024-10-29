// ------------------------------------
// Example Comments Provider
// ------------------------------------

module.exports = {
  async create({ pageId, replyTo, content, guestName, guestEmail, user }) {
    // Code to create a comment here...
  },
  async update({ id, content, user }) {
    // Code to update a comment here...
  },
  async remove({ id, user }) {
    // Code to delete a comment here...
  },
  async count({ pageId }) {
    // Code to get the comment count for a page...
  },
};
